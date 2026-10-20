import contextlib
import io
import json
import os
import unittest
from unittest.mock import MagicMock, patch

import httpx2 as httpx
from azure.core.exceptions import ClientAuthenticationError
from openai import APIConnectionError, APIStatusError, OpenAI, OpenAIError
from openai.types.chat import ChatCompletion

from scripts import chat

BASE_URL = "https://qwen-test-ai.services.ai.azure.com/openai/v1/"
ENVIRONMENT = {
    "FOUNDRY_OPENAI_BASE_URL": BASE_URL,
    "FOUNDRY_DEPLOYMENT_NAME": "qwen-demo",
}


def completion(content: str | None = "A test answer", finish_reason: str = "stop") -> ChatCompletion:
    return ChatCompletion.model_validate({
        "id": "chatcmpl-test",
        "object": "chat.completion",
        "created": 0,
        "model": "qwen-demo",
        "choices": [{
            "index": 0,
            "finish_reason": finish_reason,
            "message": {"role": "assistant", "content": content},
        }],
    })


class ChatTests(unittest.TestCase):
    def setUp(self):
        self.environment = self.enterContext(patch.dict(os.environ, ENVIRONMENT, clear=True))
        self.credential_class = self.enterContext(patch.object(chat, "DefaultAzureCredential"))
        self.credential = self.credential_class.return_value.__enter__.return_value
        self.token_provider = MagicMock(return_value="unit-test-token-not-a-real-credential")
        self.token_factory = self.enterContext(
            patch.object(chat, "get_bearer_token_provider", return_value=self.token_provider)
        )
        self.client_class = self.enterContext(patch.object(chat, "OpenAI"))
        self.client = self.client_class.return_value.__enter__.return_value
        self.client.chat.completions.create.return_value = completion()

    def invoke(self, *arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = chat.main(["--prompt", "Explain managed compute", *arguments])
        return result, stdout.getvalue(), stderr.getvalue()

    def test_success_uses_deployment_name_and_refreshable_token_provider(self):
        result, stdout, stderr = self.invoke("--max-tokens", "256")
        self.assertEqual((result, stdout, stderr), (0, "A test answer\n", ""))
        self.token_factory.assert_called_once_with(self.credential, chat.TOKEN_SCOPE)
        self.token_provider.assert_not_called()
        self.assertIs(self.client_class.call_args.kwargs["api_key"], self.token_provider)
        self.assertEqual(self.client_class.call_args.kwargs["base_url"], BASE_URL)
        self.client.chat.completions.create.assert_called_once_with(
            model="qwen-demo",
            messages=[
                {"role": "system", "content": "/no_think"},
                {"role": "user", "content": "Explain managed compute"},
            ],
            max_completion_tokens=256,
            temperature=0.7,
            top_p=0.8,
        )
        self.credential_class.return_value.__exit__.assert_called_once()
        self.client_class.return_value.__exit__.assert_called_once()

    def test_default_token_budget(self):
        self.invoke()
        self.assertEqual(self.client.chat.completions.create.call_args.kwargs["max_completion_tokens"], 512)

    def test_missing_settings_fail_before_authentication(self):
        for variable in ENVIRONMENT:
            with self.subTest(variable=variable), patch.dict(os.environ, {variable: ""}):
                result, stdout, stderr = self.invoke()
                self.assertEqual(result, 2)
                self.assertEqual(stdout, "")
                self.assertIn(variable, stderr)
        self.credential_class.assert_not_called()

    def test_reject_untrusted_or_wrong_endpoint_without_disclosing_value(self):
        endpoints = [
            "http://qwen-test-ai.services.ai.azure.com/openai/v1/",
            "https://example.com/openai/v1/",
            "https://qwen-test-ai.services.ai.azure.com.example.com/openai/v1/",
            "https://qwen-test-ai.services.ai.azure.com/api/projects/demo/openai/v1/",
            BASE_URL + "?api-key=secret-marker",
            "https://secret-marker@qwen-test-ai.services.ai.azure.com/openai/v1/",
        ]
        for endpoint in endpoints:
            with self.subTest(endpoint=endpoint), patch.dict(
                os.environ, {"FOUNDRY_OPENAI_BASE_URL": endpoint}
            ):
                result, stdout, stderr = self.invoke()
                self.assertEqual((result, stdout), (2, ""))
                self.assertNotIn("secret-marker", stderr)
        self.credential_class.assert_not_called()

    def test_normalize_endpoint_without_trailing_slash(self):
        with patch.dict(os.environ, {"FOUNDRY_OPENAI_BASE_URL": BASE_URL.rstrip("/")}):
            self.assertEqual(self.invoke()[0], 0)
        self.assertEqual(self.client_class.call_args.kwargs["base_url"], BASE_URL)

    def test_model_id_is_not_an_inference_deployment_name(self):
        with patch.dict(os.environ, {"FOUNDRY_DEPLOYMENT_NAME": "Qwen/Qwen3-8B"}):
            self.assertEqual(self.invoke()[0], 2)
        self.credential_class.assert_not_called()

    def test_deployment_name_length_boundaries(self):
        for length in [2, 64]:
            with self.subTest(length=length), patch.dict(
                os.environ, {"FOUNDRY_DEPLOYMENT_NAME": "a" * length}
            ):
                self.assertEqual(chat.load_settings()[1], "a" * length)
        for length in [1, 65]:
            with self.subTest(length=length), patch.dict(
                os.environ, {"FOUNDRY_DEPLOYMENT_NAME": "a" * length}
            ):
                with self.assertRaises(ValueError):
                    chat.load_settings()

    def test_blank_prompt(self):
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(chat.main(["--prompt", "  "]), 2)
        self.assertIn("blank", stderr.getvalue())
        self.credential_class.assert_not_called()

    def test_invalid_token_budgets(self):
        for value in ["0", "-1", "1.5", "abc"]:
            with self.subTest(value=value), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    self.invoke("--max-tokens", value)
                self.assertEqual(error.exception.code, 2)
        self.credential_class.assert_not_called()

    def test_minimum_token_budget(self):
        self.assertEqual(self.invoke("--max-tokens", "1")[0], 0)
        self.assertEqual(self.client.chat.completions.create.call_args.kwargs["max_completion_tokens"], 1)

    def test_missing_prompt(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                chat.main([])
        self.assertEqual(error.exception.code, 2)

    def test_authentication_failure_does_not_leak_details(self):
        self.client.chat.completions.create.side_effect = ClientAuthenticationError("secret-marker")
        result, stdout, stderr = self.invoke()
        self.assertEqual((result, stdout), (1, ""))
        self.assertIn("authentication failed", stderr)
        self.assertNotIn("secret-marker", stderr)

    def test_http_error_hints_without_response_body(self):
        for status in [400, 401, 403, 404, 429, 500]:
            with self.subTest(status=status):
                request = httpx.Request("POST", BASE_URL + "chat/completions")
                self.client.chat.completions.create.side_effect = APIStatusError(
                    "secret-marker",
                    response=httpx.Response(status, request=request),
                    body={"error": "secret-marker"},
                )
                result, stdout, stderr = self.invoke()
                self.assertEqual((result, stdout), (1, ""))
                self.assertIn(f"HTTP {status}", stderr)
                self.assertNotIn("secret-marker", stderr)

    def test_connection_error(self):
        self.client.chat.completions.create.side_effect = APIConnectionError(
            request=httpx.Request("POST", BASE_URL + "chat/completions")
        )
        result, stdout, stderr = self.invoke()
        self.assertEqual((result, stdout), (1, ""))
        self.assertIn("Cannot reach Foundry", stderr)

    def test_sdk_error(self):
        self.client.chat.completions.create.side_effect = OpenAIError("secret-marker")
        result, stdout, stderr = self.invoke()
        self.assertEqual((result, stdout), (1, ""))
        self.assertIn("SDK", stderr)
        self.assertNotIn("secret-marker", stderr)

    def test_no_choices(self):
        self.client.chat.completions.create.return_value = completion().model_copy(update={"choices": []})
        result, stdout, stderr = self.invoke()
        self.assertEqual((result, stdout), (1, ""))
        self.assertIn("no completion choices", stderr)

    def test_empty_answer_is_not_success(self):
        for content in [None, "", " \n ", "<think>\n\n</think>\n"]:
            with self.subTest(content=content):
                self.client.chat.completions.create.return_value = completion(content)
                result, stdout, stderr = self.invoke()
                self.assertEqual((result, stdout), (1, ""))
                self.assertIn("no answer text", stderr)

    def test_empty_thinking_block_is_removed_from_answer(self):
        self.client.chat.completions.create.return_value = completion(
            "<think>\n\n</think>\n\nA test answer"
        )
        self.assertEqual(self.invoke(), (0, "A test answer\n", ""))

    def test_unexpected_reasoning_is_not_printed(self):
        self.client.chat.completions.create.return_value = completion(
            "<think>unexpected internal reasoning</think>Answer"
        )
        result, stdout, stderr = self.invoke()
        self.assertEqual((result, stdout), (1, ""))
        self.assertIn("/no_think", stderr)
        self.assertNotIn("unexpected internal reasoning", stderr)

    def test_truncated_answer_is_not_success(self):
        self.client.chat.completions.create.return_value = completion("Partial answer", "length")
        result, stdout, stderr = self.invoke()
        self.assertEqual((result, stdout), (1, ""))
        self.assertIn("--max-tokens", stderr)

    def test_non_text_finish_is_not_success(self):
        for reason in ["content_filter", "tool_calls"]:
            with self.subTest(reason=reason):
                self.client.chat.completions.create.return_value = completion("Not a final answer", reason)
                result, stdout, stderr = self.invoke()
                self.assertEqual((result, stdout), (1, ""))
                self.assertIn("did not finish", stderr)

    def test_real_sdk_serializes_chat_request_and_calls_token_provider(self):
        requests = []

        def respond(request):
            requests.append(request)
            return httpx.Response(200, json=completion().model_dump())

        def create_client(**kwargs):
            return OpenAI(
                **kwargs,
                http_client=httpx.Client(transport=httpx.MockTransport(respond)),
            )

        self.client_class.side_effect = create_client
        result, stdout, stderr = self.invoke("--max-tokens", "256")
        self.assertEqual((result, stdout, stderr), (0, "A test answer\n", ""))
        self.assertEqual(len(requests), 1)
        self.assertEqual(str(requests[0].url), BASE_URL + "chat/completions")
        self.assertEqual(
            requests[0].headers["authorization"],
            "Bearer unit-test-token-not-a-real-credential",
        )
        payload = json.loads(requests[0].content)
        self.assertEqual(payload["model"], "qwen-demo")
        self.assertEqual(payload["max_completion_tokens"], 256)
        self.assertEqual(payload["messages"][0], {"role": "system", "content": "/no_think"})
        self.assertNotIn("chat_template_kwargs", payload)
        self.token_provider.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
