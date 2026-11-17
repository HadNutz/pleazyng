from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("tv_store_submission", ROOT / "scripts/tv_store_submission.py")
assert SPEC is not None and SPEC.loader is not None
submission = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(submission)


TESTER_PROFILE = {
    "schemaVersion": 1,
    "target": "webos-arm",
    "billingMode": "tester",
    "supporterMode": "off",
    "paymentwall": {
        "enabled": False,
        "apiOrigin": None,
        "grantPublicKeySha256": None,
        "productId": None,
        "currency": None,
        "amountCents": None,
    },
}
PAID_PROFILE = {
    "schemaVersion": 1,
    "target": "webos-arm",
    "billingMode": "paid",
    "supporterMode": "iap",
    "paymentwall": {
        "enabled": True,
        "apiOrigin": "https://billing.pleazyng.app",
        "grantPublicKeySha256": "a" * 64,
        "productId": "pleazyng_lifetime_unlock",
        "currency": "USD",
        "amountCents": 299,
    },
}


class LGHandoffGuardTests(unittest.TestCase):
    def check(
        self,
        profile: dict[str, object],
        *,
        source_commit: str = "a" * 40,
        **provenance_updates: object,
    ) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "org.snapetech.pleazyng_3.0.1_arm.ipk"
            package.write_bytes(b"ipk-fixture")
            record: dict[str, object] = {
                "sourceCommit": source_commit,
                "version": "3.0.1",
                "package": package.name,
                "packageSha256": "b" * 64,
                "lgPaymentwallBuild": profile,
            }
            record.update(provenance_updates)
            provenance = root / "webos-app-provenance.json"
            provenance.write_text(json.dumps(record), encoding="utf-8")
            verifier = types.ModuleType("verify_package")
            verifier.load_lock = lambda: {}
            verifier.verify_ipk = lambda _package, _lock: {
                "packageSha256": "b" * 64,
                "lgPaymentwallBuild": profile,
            }
            with patch.dict(sys.modules, {"verify_package": verifier}):
                return submission.verify_lg_paid_profile(package, provenance, "3.0.1", source_commit)

    def test_paid_profile_and_exact_provenance_are_required(self) -> None:
        self.assertEqual(self.check(PAID_PROFILE), PAID_PROFILE)
        with self.assertRaisesRegex(ValueError, "tester/off"):
            self.check(TESTER_PROFILE)

    def test_provenance_cannot_claim_a_different_billing_profile(self) -> None:
        with self.assertRaisesRegex(ValueError, "provenance does not match"):
            self.check(PAID_PROFILE, lgPaymentwallBuild=TESTER_PROFILE)

    def test_lg_handoff_requires_exact_source_commit(self) -> None:
        with self.assertRaisesRegex(ValueError, "exact 40-character"):
            self.check(PAID_PROFILE, source_commit="a" * 39)


if __name__ == "__main__":
    unittest.main()
