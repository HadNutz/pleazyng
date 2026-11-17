"""Tests for selecting a completed Apple app-build attempt after targeted retries."""

import copy
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import verify_apple_capture_producer as verify  # noqa: E402


RUN_ID = "44138287919"
WORKFLOW_ID = 420649233
SOURCE_SHA = "1aceb47e6fb0062d75a234af27011b45a0352793"
ARTIFACT_DIGEST = "sha256:" + "a" * 64


def fixture_documents():
    run = {
        "id": int(RUN_ID),
        "run_attempt": 2,
        "status": "queued",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": SOURCE_SHA,
        "workflow_id": WORKFLOW_ID,
        "repository": {"id": 1433487464, "full_name": verify.REPOSITORY},
    }
    attempt = {
        "id": int(RUN_ID),
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "failure",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": SOURCE_SHA,
        "workflow_id": WORKFLOW_ID,
    }
    jobs = {
        "jobs": [{
            "id": 134233774237,
            "run_id": int(RUN_ID),
            "run_attempt": 1,
            "name": "macos",
            "status": "completed",
            "conclusion": "failure",
            "steps": [
                {"number": 4, "name": "Verify the exact product source", "conclusion": "success"},
                {"number": 19, "name": "Build the unsigned Mac App Store candidate", "conclusion": "success"},
                {
                    "number": 20,
                    "name": "Preserve the compiled unsigned Mac app before capture",
                    "conclusion": "success",
                },
                {
                    "number": 21,
                    "name": "Run actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9",
                    "conclusion": "success",
                },
                {"number": 22, "name": "Capture the actual macOS app window", "conclusion": "failure"},
            ],
        }]
    }
    artifacts = {
        "artifacts": [{
            "id": 14360907775,
            "name": "apple-store-build-macos-3.0.38",
            "digest": ARTIFACT_DIGEST,
            "size_in_bytes": 255880528,
            "created_at": "2026-11-17T19:15:05Z",
            "expired": False,
            "workflow_run": {
                "id": int(RUN_ID),
                "head_branch": "main",
                "head_sha": SOURCE_SHA,
                "repository_id": 1433487464,
                "head_repository_id": 1433487464,
            },
        }]
    }
    return run, attempt, jobs, artifacts


class VerifyMacProducerAttemptTest(unittest.TestCase):
    def validate(self, documents):
        return verify.validate_macos_producer_attempt(
            *documents,
            run_id=RUN_ID,
            attempt_number=1,
            workflow_id=WORKFLOW_ID,
            artifact_name="apple-store-build-macos-3.0.38",
            capture_target="macos-in-use-diagnostic-only",
            consumer_workflow_sha="b" * 40,
            product_source_sha=SOURCE_SHA,
            product_version="3.0.38",
            product_build="197",
        )

    def test_accepts_completed_mac_artifact_attempt_while_unrelated_retry_is_queued(self):
        receipt = self.validate(fixture_documents())

        self.assertEqual(receipt["producer_run_attempt"], 1)
        self.assertEqual(receipt["producer_run_latest_attempt"], 2)
        self.assertFalse(receipt["selected_attempt_is_latest"])
        self.assertEqual(receipt["producer_attempt_conclusion"], "failure")
        self.assertEqual(receipt["producer_job"]["conclusion"], "failure")
        self.assertEqual(receipt["artifact"]["id"], 14360907775)
        self.assertEqual(receipt["artifact"]["sha256"], "a" * 64)

    def test_latest_attempt_must_still_be_a_completed_run(self):
        docs = fixture_documents()
        docs[0]["run_attempt"] = 1
        docs[0]["status"] = "in_progress"
        docs[1]["status"] = "completed"
        message = "latest producer attempt must still pass the completed-run check"
        with self.assertRaisesRegex(verify.ProducerVerificationError, message):
            self.validate(docs)

    def test_requires_successful_build_preservation_and_immediate_upload(self):
        docs = fixture_documents()
        docs[2]["jobs"][0]["steps"][1]["conclusion"] = "failure"
        message = "Build the unsigned Mac App Store candidate"
        with self.assertRaisesRegex(verify.ProducerVerificationError, message):
            self.validate(docs)

        docs = fixture_documents()
        docs[2]["jobs"][0]["steps"][3]["conclusion"] = "failure"
        with self.assertRaisesRegex(verify.ProducerVerificationError, "artifact-upload step"):
            self.validate(docs)

    def test_requires_unique_artifact_with_exact_run_source_and_digest(self):
        docs = fixture_documents()
        docs[3]["artifacts"].append(copy.deepcopy(docs[3]["artifacts"][0]))
        message = "exactly one active Mac build artifact"
        with self.assertRaisesRegex(verify.ProducerVerificationError, message):
            self.validate(docs)

        docs = fixture_documents()
        docs[3]["artifacts"][0]["workflow_run"]["head_sha"] = "c" * 40
        with self.assertRaisesRegex(verify.ProducerVerificationError, "workflow SHA differs"):
            self.validate(docs)

        docs = fixture_documents()
        docs[3]["artifacts"][0]["digest"] = "sha256:bad"
        with self.assertRaisesRegex(verify.ProducerVerificationError, "valid SHA-256 digest"):
            self.validate(docs)

    def test_rejects_wrong_attempt_job_and_non_mac_target(self):
        docs = fixture_documents()
        docs[2]["jobs"][0]["run_attempt"] = 2
        with self.assertRaisesRegex(verify.ProducerVerificationError, "different run attempt"):
            self.validate(docs)

        docs = fixture_documents()
        with self.assertRaisesRegex(verify.ProducerVerificationError, "Mac producer attempt is valid only"):
            verify.validate_macos_producer_attempt(
                *docs,
                run_id=RUN_ID,
                attempt_number=1,
                workflow_id=WORKFLOW_ID,
                artifact_name="apple-store-build-macos-3.0.38",
                capture_target="tvos-in-use-capture-only",
                consumer_workflow_sha="b" * 40,
                product_source_sha=SOURCE_SHA,
                product_version="3.0.38",
                product_build="197",
            )


class WorkflowWiringTest(unittest.TestCase):
    def test_explicit_attempt_is_opt_in_and_latest_run_gate_is_unchanged(self):
        workflow = (ROOT / ".github/workflows/apple-store-screenshots.yml").read_text(encoding="utf-8")
        self.assertIn("macos_artifact_run_attempt:", workflow)
        self.assertIn("attempts/$PRODUCER_RUN_ATTEMPT_INPUT/jobs", workflow)
        self.assertIn("verify_apple_capture_producer.py", workflow)
        self.assertIn("--producer-run-attempt \"$PRODUCER_RUN_ATTEMPT\"", workflow)
        self.assertIn(".status == \\\"completed\\\"", workflow)
        condition = "inputs.target == 'macos-in-use-diagnostic-only' && "
        self.assertIn(condition + "inputs.macos_artifact_run_attempt != ''", workflow)


if __name__ == "__main__":
    unittest.main()
