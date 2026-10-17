package com.oldjin.meetnote

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Gemini API 키는 Android Keystore(AES-GCM)로 암호화해 저장한다. */
object Prefs {
    const val DEFAULT_MODEL = "gemini-2.5-flash"
    private const val ALIAS = "meetnote_api_key"

    private fun sp(ctx: Context) = ctx.getSharedPreferences("meetnote", Context.MODE_PRIVATE)

    private fun secretKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return gen.generateKey()
    }

    fun apiKey(ctx: Context): String? {
        val raw = sp(ctx).getString("api_key", null) ?: return null
        return try {
            val (iv, ct) = raw.split(":").map { Base64.decode(it, Base64.NO_WRAP) }
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
            String(c.doFinal(ct), Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
    }

    fun setApiKey(ctx: Context, key: String) {
        if (key.isBlank()) {
            sp(ctx).edit().remove("api_key").apply()
            return
        }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, secretKey())
        val ct = c.doFinal(key.trim().toByteArray(Charsets.UTF_8))
        val enc = Base64.encodeToString(c.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(ct, Base64.NO_WRAP)
        sp(ctx).edit().putString("api_key", enc).apply()
    }

    fun model(ctx: Context): String = sp(ctx).getString("model", DEFAULT_MODEL) ?: DEFAULT_MODEL
    fun setModel(ctx: Context, m: String) = sp(ctx).edit().putString("model", m.trim().ifBlank { DEFAULT_MODEL }).apply()
}
