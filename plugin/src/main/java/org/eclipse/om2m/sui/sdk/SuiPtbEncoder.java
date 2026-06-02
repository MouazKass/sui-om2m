package org.eclipse.om2m.sui.sdk;

import java.util.ArrayList;
import java.util.List;

/**
 * Builds a BCS-encoded Sui TransactionData::V1 for our 6-step PTB.
 *
 * Mirrors the wire format proved by tonight's curl test (digest
 * C8EcSPYGa2YUWnJkUEWets564ZDBLkscxRETwr8XBLFv on testnet).
 *
 * Reference: sui/crates/sui-types/src/transaction.rs
 */
public final class SuiPtbEncoder {

    // ---- Input representations ----

    /** A reference to an owned or immutable object. */
    public static final class ObjectRef {
        public final byte[] objectId;        // 32 bytes
        public final long version;           // SequenceNumber (u64)
        public final byte[] digest;          // 32 bytes (already decoded from base58)

        public ObjectRef(byte[] objectId, long version, byte[] digest) {
            if (objectId.length != 32) throw new IllegalArgumentException("objectId not 32 bytes");
            if (digest.length != 32) throw new IllegalArgumentException("digest not 32 bytes");
            this.objectId = objectId;
            this.version = version;
            this.digest = digest;
        }
    }

    /** Reference to a shared object. */
    public static final class SharedRef {
        public final byte[] objectId;        // 32 bytes
        public final long initialSharedVersion;
        public final boolean mutable;

        public SharedRef(byte[] objectId, long initialSharedVersion, boolean mutable) {
            if (objectId.length != 32) throw new IllegalArgumentException("objectId not 32 bytes");
            this.objectId = objectId;
            this.initialSharedVersion = initialSharedVersion;
            this.mutable = mutable;
        }
    }

    /** A CallArg, the input to a Move call. */
    public static abstract class CallArg {
        abstract void encode(BcsEncoder e);

        public static CallArg pure(byte[] bytes) {
            return new PureArg(bytes);
        }
        public static CallArg ownedObject(ObjectRef ref) {
            return new OwnedObjectArg(ref);
        }
        public static CallArg sharedObject(SharedRef ref) {
            return new SharedObjectArg(ref);
        }
    }

    static final class PureArg extends CallArg {
        final byte[] bytes;
        PureArg(byte[] bytes) { this.bytes = bytes; }
        void encode(BcsEncoder e) {
            e.writeUleb128(0);    // CallArg::Pure variant
            e.writeBytes(bytes);  // Vec<u8>
        }
    }

    static final class OwnedObjectArg extends CallArg {
        final ObjectRef ref;
        OwnedObjectArg(ObjectRef ref) { this.ref = ref; }
        void encode(BcsEncoder e) {
            e.writeUleb128(1);    // CallArg::Object variant
            e.writeUleb128(0);    // ObjectArg::ImmOrOwnedObject variant
            e.writeAddress(ref.objectId);
            e.writeU64(ref.version);
            e.writeObjectDigest(ref.digest);
        }
    }

    static final class SharedObjectArg extends CallArg {
        final SharedRef ref;
        SharedObjectArg(SharedRef ref) { this.ref = ref; }
        void encode(BcsEncoder e) {
            e.writeUleb128(1);    // CallArg::Object variant
            e.writeUleb128(1);    // ObjectArg::SharedObject variant
            e.writeAddress(ref.objectId);
            e.writeU64(ref.initialSharedVersion);
            e.writeBool(ref.mutable);
        }
    }

    /** An Argument to a Move call: refers to inputs, results, or gas. */
    public static abstract class Arg {
        abstract void encode(BcsEncoder e);

        public static Arg gasCoin() { return GAS_COIN; }
        public static Arg input(int idx) { return new InputArg(idx); }
        public static Arg result(int cmdIdx) { return new ResultArg(cmdIdx); }
        public static Arg nestedResult(int cmdIdx, int resultIdx) {
            return new NestedResultArg(cmdIdx, resultIdx);
        }
    }

    static final Arg GAS_COIN = new Arg() {
        void encode(BcsEncoder e) { e.writeUleb128(0); }
    };

    static final class InputArg extends Arg {
        final int idx;
        InputArg(int idx) { this.idx = idx; }
        void encode(BcsEncoder e) {
            e.writeUleb128(1);
            e.writeU16(idx);
        }
    }

    static final class ResultArg extends Arg {
        final int idx;
        ResultArg(int idx) { this.idx = idx; }
        void encode(BcsEncoder e) {
            e.writeUleb128(2);
            e.writeU16(idx);
        }
    }

    static final class NestedResultArg extends Arg {
        final int cmdIdx, resultIdx;
        NestedResultArg(int c, int r) { this.cmdIdx = c; this.resultIdx = r; }
        void encode(BcsEncoder e) {
            e.writeUleb128(3);
            e.writeU16(cmdIdx);
            e.writeU16(resultIdx);
        }
    }

    /** A MoveCall command. */
    public static final class MoveCall {
        public final byte[] packageId;       // 32 bytes
        public final String module;
        public final String function;
        public final List<Arg> arguments;
        // type_arguments empty for our PTB

        public MoveCall(byte[] packageId, String module, String function, List<Arg> args) {
            if (packageId.length != 32) throw new IllegalArgumentException("packageId not 32 bytes");
            this.packageId = packageId;
            this.module = module;
            this.function = function;
            this.arguments = args;
        }

        void encode(BcsEncoder e) {
            e.writeUleb128(0);          // Command::MoveCall variant
            e.writeAddress(packageId);
            e.writeString(module);
            e.writeString(function);
            e.writeUleb128(0);          // type_arguments: Vec<TypeTag>, empty
            e.writeUleb128(arguments.size());
            for (Arg a : arguments) a.encode(e);
        }
    }

    // ---- Top-level builder ----

    private final List<CallArg> inputs = new ArrayList<>();
    private final List<MoveCall> commands = new ArrayList<>();

    public int addInput(CallArg arg) {
        inputs.add(arg);
        return inputs.size() - 1;
    }

    public int addMoveCall(MoveCall mc) {
        commands.add(mc);
        return commands.size() - 1;
    }

    /**
     * Build the full BCS-encoded TransactionData::V1.
     *
     * @param sender 32-byte sender address
     * @param gasPayment list of owned coin ObjectRefs to pay gas
     * @param gasPrice reference gas price (use 1000 on testnet)
     * @param gasBudget total gas budget (MIST)
     */
        public byte[] encodeTransactionData(byte[] sender,
                                        List<ObjectRef> gasPayment,
                                        long gasPrice,
                                        long gasBudget) {
        BcsEncoder e = new BcsEncoder();
        e.writeUleb128(0);
        e.writeRawBytes(encodeTransactionKind());
        e.writeAddress(sender);
        e.writeUleb128(gasPayment.size());
        for (ObjectRef r : gasPayment) {
            e.writeAddress(r.objectId);
            e.writeU64(r.version);
            e.writeObjectDigest(r.digest);
        }
        e.writeAddress(sender);
        e.writeU64(gasPrice);
        e.writeU64(gasBudget);
        e.writeUleb128(0);
        return e.toBytes();
    }

    /** TransactionKind::ProgrammableTransaction body only (for devInspect). */
    public byte[] encodeTransactionKind() {
        BcsEncoder e = new BcsEncoder();
        e.writeUleb128(0);
        e.writeUleb128(inputs.size());
        for (CallArg a : inputs) a.encode(e);
        e.writeUleb128(commands.size());
        for (MoveCall mc : commands) mc.encode(e);
        return e.toBytes();
    }

}
