package com.younum.app

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import java.security.SecureRandom

/**
 * 数据库口令的保管。
 *
 * 目标是「数据库文件被拿走也读不出内容」，同时不引入用户要记的密码。
 * 做法是标准的两层：
 *
 * 1. 随机生成一个 32 字节的**口令**，交给 SQLCipher 打开数据库；
 * 2. 口令本身用 **Android Keystore 里的一把 AES 密钥**加密后存成文件。
 *
 * 关键点在那把 AES 密钥：它生成在 Keystore 里、**永远不出来**（不可导出），
 * 所以只把文件拷走是解不开口令的；要在别的设备上还原，Keystore 里没有那把
 * 密钥，同样解不开。
 *
 * ⚠️ 代价必须说清楚（已经写进文档与界面上）：密钥丢了就等于数据永久读不出。
 * 卸载应用、清应用数据、换手机会让 Keystore 里的密钥消失 —— 这是加密的
 * 必然结果，不是缺陷。所以「退出/换机前先导出」这件事要在隐私页写明。
 *
 * 另外：**不要把口令写进日志**。日志在真机上是能被 adb 读到的。
 */
class DatabaseKeyStore(private val filesDir: File) {

    companion object {
        private const val TAG = "YounumSecurity"

        /** Android 的系统密钥库。 */
        private const val KEYSTORE = "AndroidKeyStore"

        /** 保管口令的那把 AES 密钥的别名。 */
        private const val KEY_ALIAS = "younum.database.key"

        /** 包裹后的口令存在这里。 */
        private const val FILE_NAME = "younum.database.key"

        private const val GCM_TAG_BITS = 128
        private const val GCM_IV_BYTES = 12

        /** 口令长度：32 字节（256 位），够用且不啰嗦。 */
        private const val PASSPHRASE_BYTES = 32

        /** 分隔符：`base64(iv):base64(密文)`。 */
        private const val SEPARATOR = ":"
    }

    /**
     * 拿口令：第一次调用会生成并由 Keystore 包住，之后原样取回。
     *
     * 取不出来（Keystore 里的密钥没了、文件被改坏、换了设备）会**抛异常**，
     * 而不是悄悄生成一把新的 —— 后者会让用户在毫无察觉的情况下「数据全没了」：
     * 新的口令打不开旧库，应用会给他一个空账本，看起来就像账单被删了。
     */
    @Throws(DatabaseKeyUnavailable::class)
    fun getOrCreatePassphrase(): String {
        val wrapped = File(filesDir, FILE_NAME)
        if (wrapped.exists()) {
            return unwrap(wrapped.readText())
        }

        val passphrase = ByteArray(PASSPHRASE_BYTES).also {
            SecureRandom().nextBytes(it)
        }
        val encoded = wrap(passphrase)
        wrapped.writeText(encoded)
        // 口令只以密文形态落盘，内存里这份用完就还回去。
        val text = Base64.encodeToString(passphrase, Base64.NO_WRAP)
        passphrase.fill(0)
        return text
    }

    private fun keyStore(): KeyStore =
        KeyStore.getInstance(KEYSTORE).apply { load(null) }

    private fun secretKey(createIfMissing: Boolean): SecretKey? {
        val store = keyStore()
        (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }
        if (!createIfMissing) return null

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                // 不要求解锁才能用：口径与数据库本身一致（数据在应用私有目录里，
                // 已经受系统的应用沙箱保护）。要求生物识别会带来
                // 「锁屏后后台任务打不开数据库」这类问题，收益却很小。
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private fun wrap(passphrase: ByteArray): String {
        val key = secretKey(createIfMissing = true)
            ?: throw DatabaseKeyUnavailable("密钥库里没能生成密钥")

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val cipherText = cipher.doFinal(passphrase)
        val iv = Base64.encodeToString(cipher.iv, Base64.NO_WRAP)
        val body = Base64.encodeToString(cipherText, Base64.NO_WRAP)
        return iv + SEPARATOR + body
    }

    private fun unwrap(encoded: String): String {
        val parts = encoded.trim().split(SEPARATOR)
        if (parts.size != 2) {
            throw DatabaseKeyUnavailable("口令文件坏了（格式不对）")
        }
        val key = secretKey(createIfMissing = false)
            ?: throw DatabaseKeyUnavailable("系统里的数据库密钥不见了")

        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val iv = Base64.decode(parts[0], Base64.NO_WRAP)
            if (iv.size != GCM_IV_BYTES) {
                throw DatabaseKeyUnavailable("口令文件坏了（IV 长度不对）")
            }
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
            val passphrase = cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP))
            val text = Base64.encodeToString(passphrase, Base64.NO_WRAP)
            passphrase.fill(0)
            text
        } catch (error: DatabaseKeyUnavailable) {
            throw error
        } catch (error: Exception) {
            // 最常见的原因是「换了设备 / 清了数据」：密钥没了或对不上。
            throw DatabaseKeyUnavailable("解不开数据库口令：${error.message}")
        }
    }
}

/** 口令取不出来。消息可以直接给用户看。 */
class DatabaseKeyUnavailable(message: String) : Exception(message)
