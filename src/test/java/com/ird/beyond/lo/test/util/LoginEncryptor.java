package com.ird.beyond.lo.test.util;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.OAEPParameterSpec;
import javax.crypto.spec.PSource;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.SecureRandom;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.MGF1ParameterSpec;
import java.security.spec.X509EncodedKeySpec;
import java.util.Base64;

/**
 * Encrypts user credentials for the /auth/login challenge protocol
 * (RSA-OAEP-256 + AES-256-GCM) matching LoginChallengeService and auth.service.ts.
 */
public class LoginEncryptor {

    public static String encrypt(String challengeId, String publicKeyB64, String nonce, String password) throws Exception {
        String cleanKey = publicKeyB64.replaceAll("\\s+", "");
        RSAPublicKey pub = (RSAPublicKey) KeyFactory.getInstance("RSA")
                .generatePublic(new X509EncodedKeySpec(Base64.getDecoder().decode(cleanKey)));

        KeyGenerator kg = KeyGenerator.getInstance("AES");
        kg.init(256);
        SecretKey aes = kg.generateKey();

        byte[] iv = new byte[12];
        new SecureRandom().nextBytes(iv);

        String escapedPassword = password == null ? "" : password.replace("\\", "\\\\").replace("\"", "\\\"");
        String json = "{\"nonce\":\"" + nonce + "\",\"password\":\"" + escapedPassword + "\"}";

        Cipher gcm = Cipher.getInstance("AES/GCM/NoPadding");
        gcm.init(Cipher.ENCRYPT_MODE, aes, new GCMParameterSpec(128, iv));
        gcm.updateAAD(challengeId.getBytes(StandardCharsets.UTF_8));
        byte[] ct = gcm.doFinal(json.getBytes(StandardCharsets.UTF_8));

        Cipher rsa = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding");
        rsa.init(Cipher.ENCRYPT_MODE, pub,
                new OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, PSource.PSpecified.DEFAULT));
        byte[] wrapped = rsa.doFinal(aes.getEncoded());

        Base64.Encoder b64 = Base64.getEncoder();
        return b64.encodeToString(wrapped) + "." + b64.encodeToString(iv) + "." + b64.encodeToString(ct);
    }
}
