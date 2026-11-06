package com.notevibe.notevibe

import android.app.Activity
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

/** Password envelope bound to a per-use biometric Keystore operation. No
 * reusable authentication flag and no plaintext password in preferences. */
class VaultBiometrics(private val activity: Activity) {
    private val alias = "notevibe_vault_biometric_v1"
    private val prefs get() = activity.getSharedPreferences("vault_biometrics", 0)
    private var busy = false
    fun handle(method: String, password: String?, result: MethodChannel.Result) {
        if (method == "vaultBioStatus") {
            result.success(Build.VERSION.SDK_INT >= 28 && prefs.contains("ciphertext")); return
        }
        if (method == "vaultBioDisable") {
            if (busy) { result.error("busy", "Дождитесь завершения проверки", null); return }
            prefs.edit().clear().commit()
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            store.deleteEntry(alias)
            result.success(null); return
        }
        if (Build.VERSION.SDK_INT < 28) { result.error("unsupported", "Биометрия требует Android 9 или новее", null); return }
        if (busy) { result.error("busy", "Проверка уже выполняется", null); return }
        try {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val enroll = method == "vaultBioEnable"
            if (enroll) {
                require(!password.isNullOrEmpty())
                // Re-enrollment invalidates any previous biometric envelope.
                prefs.edit().clear().commit()
                store.deleteEntry(alias)
                val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                val builder = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256).setUserAuthenticationRequired(true).setInvalidatedByBiometricEnrollment(true)
                if (Build.VERSION.SDK_INT >= 30) builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                else builder.setUserAuthenticationValidityDurationSeconds(-1)
                generator.init(builder.build())
                cipher.init(Cipher.ENCRYPT_MODE, generator.generateKey())
            } else {
                val iv = Base64.decode(prefs.getString("iv", null) ?: error("Вход по биометрии не настроен"), Base64.NO_WRAP)
                cipher.init(Cipher.DECRYPT_MODE, store.getKey(alias, null), GCMParameterSpec(128, iv))
            }
            val prompt = BiometricPrompt.Builder(activity).setTitle("Разблокировать NoteVibe")
                .setSubtitle(if (enroll) "Подтвердите подключение отпечатка" else "Подтвердите доступ к зашифрованным заметкам")
                .setNegativeButton("Ввести пароль", activity.mainExecutor) { _, _ ->
                    if (busy) { busy = false; result.error("cancelled", "Используйте пароль", null) }
                }
            if (Build.VERSION.SDK_INT >= 30) prompt.setAllowedAuthenticators(android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG)
            busy = true
            prompt.build().authenticate(BiometricPrompt.CryptoObject(cipher), CancellationSignal(), activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        if (busy) { busy = false; result.error("biometric", message.toString(), null) }
                    }
                    override fun onAuthenticationSucceeded(authentication: BiometricPrompt.AuthenticationResult) {
                        if (!busy) return
                        busy = false
                        try {
                            val authenticated = authentication.cryptoObject?.cipher ?: error("Не подтверждён ключ")
                            if (enroll) {
                                val bytes = password!!.toByteArray(Charsets.UTF_8)
                                val encrypted = try { authenticated.doFinal(bytes) } finally { bytes.fill(0) }
                                check(prefs.edit().putString("iv", Base64.encodeToString(authenticated.iv, Base64.NO_WRAP))
                                    .putString("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit())
                                result.success(null)
                            } else {
                                val encrypted = Base64.decode(prefs.getString("ciphertext", null), Base64.NO_WRAP)
                                val bytes = authenticated.doFinal(encrypted)
                                try { result.success(String(bytes, Charsets.UTF_8)) } finally { bytes.fill(0) }
                            }
                        } catch (_: Exception) { result.error("biometric", "Не удалось открыть ключ. Введите пароль", null) }
                    }
                })
        } catch (_: Exception) { busy = false; result.error("biometric", "Биометрия недоступна или изменилась. Используйте пароль", null) }
    }
}
