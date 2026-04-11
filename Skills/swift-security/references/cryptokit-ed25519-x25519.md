# Ed25519 seed vs X25519 scalar in CryptoKit

Sharing `rawRepresentation` between CryptoKit's `Curve25519.Signing.PrivateKey` and `Curve25519.KeyAgreement.PrivateKey` gives **different** key pairs — the Ed25519 public key and the X25519 public key won't correspond via the birational map.


## Why

CryptoKit's `Curve25519.Signing.PrivateKey.rawRepresentation` returns the 32-byte **seed**, not the secret scalar. Ed25519 derives the scalar internally via `SHA512(seed)[0..31]` with bit clamping. X25519's `Curve25519.KeyAgreement.PrivateKey(rawRepresentation:)` uses its bytes directly as the scalar.

The birational map `u = (1+y)/(1-y)` converts between Ed25519 and X25519 public keys that share the **same** scalar. If the scalars differ (seed vs hash-derived), the conversion produces the wrong result.


## How to apply

When deriving an X25519 agreement key from an Ed25519 identity key (e.g. in an OMEMO / X3DH setting), hash the seed first:

```swift
import CryptoKit

let signingKey: Curve25519.Signing.PrivateKey = ...
let hash = SHA512.hash(data: signingKey.rawRepresentation)
let scalar = Array(hash.prefix(32))
let agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
```

The corresponding X25519 public key now matches the birational-map conversion of the Ed25519 public key, and ECDH results will agree with a peer who uses the same derivation.

This gotcha is easy to miss because both `rawRepresentation` call sites are the same 32 bytes — the bug only surfaces when a peer computes the X25519 public key via the birational map from your Ed25519 public key and finds it doesn't match.
