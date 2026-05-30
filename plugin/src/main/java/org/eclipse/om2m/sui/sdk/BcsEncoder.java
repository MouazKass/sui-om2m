package org.eclipse.om2m.sui.sdk;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;

/**
 * Minimal BCS (Binary Canonical Serialization) writer for the subset
 * of Sui's TransactionData that our 6-step PTB needs.
 *
 * BCS is Move/Sui's canonical binary format:
 *   - Primitives: little-endian fixed width
 *   - Vec<T>: ULEB128 length prefix + concatenated elements
 *   - Struct: fields in declaration order, no length prefix
 *   - Enum: ULEB128 variant index + variant payload
 *   - Option<T>: 0x00 for None, 0x01 followed by T for Some
 *
 * Reference: https://docs.rs/bcs/latest/bcs/
 */
public final class BcsEncoder {

    private final ByteArrayOutputStream out = new ByteArrayOutputStream();

    public byte[] toBytes() {
        return out.toByteArray();
    }

    // ---- primitives ----

    public BcsEncoder writeBool(boolean b) {
        out.write(b ? 1 : 0);
        return this;
    }

    public BcsEncoder writeU8(int v) {
        out.write(v & 0xFF);
        return this;
    }

    public BcsEncoder writeU16(int v) {
        out.write(v & 0xFF);
        out.write((v >> 8) & 0xFF);
        return this;
    }

    public BcsEncoder writeU32(long v) {
        for (int i = 0; i < 4; i++) out.write((int) ((v >> (8 * i)) & 0xFF));
        return this;
    }

    public BcsEncoder writeU64(long v) {
        for (int i = 0; i < 8; i++) out.write((int) ((v >>> (8 * i)) & 0xFF));
        return this;
    }

    public BcsEncoder writeU128(BigInteger v) {
        byte[] le = toLittleEndian(v, 16);
        try { out.write(le); } catch (IOException e) { throw new RuntimeException(e); }
        return this;
    }

    public BcsEncoder writeU256(BigInteger v) {
        byte[] le = toLittleEndian(v, 32);
        try { out.write(le); } catch (IOException e) { throw new RuntimeException(e); }
        return this;
    }

    /** ULEB128 unsigned-leb encoding for vec lengths and enum variant indices. */
    public BcsEncoder writeUleb128(long value) {
        while ((value & ~0x7FL) != 0) {
            out.write((int) ((value & 0x7F) | 0x80));
            value >>>= 7;
        }
        out.write((int) (value & 0x7F));
        return this;
    }

    public BcsEncoder writeRawBytes(byte[] bytes) {
        try { out.write(bytes); } catch (IOException e) { throw new RuntimeException(e); }
        return this;
    }

    /** Vec<u8> with length prefix. Use this for byte arrays as struct fields. */
    public BcsEncoder writeBytes(byte[] bytes) {
        writeUleb128(bytes.length);
        return writeRawBytes(bytes);
    }

    /** String -> Vec<u8> (UTF-8). */
    public BcsEncoder writeString(String s) {
        return writeBytes(s.getBytes(StandardCharsets.UTF_8));
    }

    /** SuiAddress: 32 raw bytes, NO length prefix. */
    public BcsEncoder writeAddress(byte[] addr32) {
        if (addr32.length != 32) {
            throw new IllegalArgumentException("address must be 32 bytes, got " + addr32.length);
        }
        return writeRawBytes(addr32);
    }

    /** ObjectDigest: Vec<u8> = ULEB128(32) + 32 raw bytes. */
    public BcsEncoder writeObjectDigest(byte[] digest32) {
        if (digest32.length != 32) {
            throw new IllegalArgumentException("digest must be 32 bytes, got " + digest32.length);
        }
        return writeBytes(digest32);  // length-prefixed
    }

    // ---- helpers ----

    private static byte[] toLittleEndian(BigInteger v, int width) {
        byte[] be = v.toByteArray(); // big-endian, possibly with leading 0x00 sign byte
        byte[] le = new byte[width];
        int copyLen = Math.min(be.length, width);
        for (int i = 0; i < copyLen; i++) {
            le[i] = be[be.length - 1 - i];
        }
        return le;
    }

    /** Hex 0x... → 32-byte array (Sui addresses & object IDs). */
    public static byte[] hexTo32(String hex) {
        if (hex.startsWith("0x")) hex = hex.substring(2);
        // Pad left to 64 hex chars (32 bytes)
        if (hex.length() < 64) {
            StringBuilder sb = new StringBuilder(64);
            for (int i = hex.length(); i < 64; i++) sb.append('0');
            sb.append(hex);
            hex = sb.toString();
        }
        if (hex.length() != 64) {
            throw new IllegalArgumentException("expected 32-byte hex, got " + hex.length() + " chars");
        }
        byte[] out = new byte[32];
        for (int i = 0; i < 32; i++) {
            out[i] = (byte) Integer.parseInt(hex.substring(2 * i, 2 * i + 2), 16);
        }
        return out;
    }

    /** Base58 decode for ObjectDigest values from RPC. */
    public static byte[] base58Decode(String s) {
        // Sui ObjectDigests come back as base58 strings. Need decoding.
        String ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        java.math.BigInteger num = java.math.BigInteger.ZERO;
        java.math.BigInteger base = java.math.BigInteger.valueOf(58);
        int leadingZeros = 0;
        boolean stillLeading = true;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            int idx = ALPHABET.indexOf(c);
            if (idx < 0) throw new IllegalArgumentException("invalid base58 char: " + c);
            if (stillLeading && c == '1') leadingZeros++;
            else stillLeading = false;
            num = num.multiply(base).add(java.math.BigInteger.valueOf(idx));
        }
        byte[] raw = num.toByteArray();
        // Strip BigInteger sign byte if present
        if (raw.length > 0 && raw[0] == 0) {
            byte[] stripped = new byte[raw.length - 1];
            System.arraycopy(raw, 1, stripped, 0, stripped.length);
            raw = stripped;
        }
        byte[] out = new byte[leadingZeros + raw.length];
        System.arraycopy(raw, 0, out, leadingZeros, raw.length);
        return out;
    }
}
