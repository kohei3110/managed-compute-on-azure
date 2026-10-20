"""Call a Qwen chat deployment on the public-cloud Foundry account endpoint."""

import argparse
import os
import re
import sys
from collections.abc import Sequence

from azure.core.exceptions import ClientAuthenticationError
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import APIConnectionError, APIStatusError, OpenAI, OpenAIError

TOKEN_SCOPE = "https://cognitiveservices.azure.com/.default"


def positive_integer(value: str) -> int:
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def load_settings() -> tuple[str, str]:
    base_url = os.environ.get("FOUNDRY_OPENAI_BASE_URL", "").strip()
    deployment = os.environ.get("FOUNDRY_DEPLOYMENT_NAME", "").strip()

    if not re.fullmatch(
        r"https://[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
        r"\.services\.ai\.azure\.com/openai/v1/?",
        base_url,
    ):
        raise ValueError(
            "Set FOUNDRY_OPENAI_BASE_URL to the Terraform openai_base_url output "
            "(https://<account>.services.ai.azure.com/openai/v1/)."
        )
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{1,63}", deployment):
        raise ValueError(
            "Set FOUNDRY_DEPLOYMENT_NAME to the Terraform deployment_name output. "
            "The GPU deployment must be enabled and Succeeded."
        )
    return base_url.rstrip("/") + "/", deployment


def status_error_message(status_code: int) -> str:
    hints = {
        400: "Check the model, token limit, and supported standard Chat Completions parameters.",
        401: "Run az login and check that the credential belongs to the intended tenant.",
        403: "Check Foundry User on the account and allow RBAC propagation.",
        404: "Check the base URL, deployment name, Succeeded state, and chat-completions support.",
        429: "Check throttling and Managed compute capacity; retry later.",
    }
    hint = hints.get(status_code, "Check deployment health and the Foundry service status.")
    return f"HTTP {status_code}: {hint}"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prompt", required=True, help="Single user prompt.")
    parser.add_argument(
        "--max-tokens",
        type=positive_integer,
        default=512,
        help="Maximum completion tokens (default: 512).",
    )
    args = parser.parse_args(argv)

    if not args.prompt.strip():
        print("Error: --prompt must not be blank.", file=sys.stderr)
        return 2

    try:
        base_url, deployment = load_settings()
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2

    try:
        with DefaultAzureCredential(exclude_interactive_browser_credential=True) as credential:
            token_provider = get_bearer_token_provider(credential, TOKEN_SCOPE)
            with OpenAI(
                base_url=base_url,
                api_key=token_provider,
                timeout=60.0,
            ) as client:
                response = client.chat.completions.create(
                    model=deployment,
                    messages=[
                        {"role": "system", "content": "/no_think"},
                        {"role": "user", "content": args.prompt},
                    ],
                    max_completion_tokens=args.max_tokens,
                    temperature=0.7,
                    top_p=0.8,
                )
    except ClientAuthenticationError:
        print(
            "Error: Entra ID authentication failed. Run az login or configure "
            "DefaultAzureCredential for the intended identity.",
            file=sys.stderr,
        )
        return 1
    except APIConnectionError:
        print("Error: Cannot reach Foundry. Check DNS, network access, and the endpoint.", file=sys.stderr)
        return 1
    except APIStatusError as error:
        print(f"Error: {status_error_message(error.status_code)}", file=sys.stderr)
        return 1
    except OpenAIError:
        print("Error: The OpenAI SDK could not process the request or response.", file=sys.stderr)
        return 1

    if not response.choices:
        print("Error: Foundry returned no completion choices.", file=sys.stderr)
        return 1

    choice = response.choices[0]
    if choice.finish_reason == "length":
        print(
            "Error: The token limit was reached before completion. Increase --max-tokens "
            "or verify that Qwen honors /no_think.",
            file=sys.stderr,
        )
        return 1
    if choice.finish_reason != "stop":
        print(
            "Error: The model did not finish a text answer; check filtering or template behavior.",
            file=sys.stderr,
        )
        return 1
    # Qwen's soft switch can emit an empty thinking block before the answer.
    content = re.sub(r"\A<think>\s*</think>\s*", "", (choice.message.content or "").strip())
    if not content:
        print(
            "Error: The model returned no answer text. Check the token budget "
            "and Qwen non-thinking/template configuration.",
            file=sys.stderr,
        )
        return 1
    if content.startswith("<think>"):
        print(
            "Error: Qwen returned unexpected reasoning instead of honoring /no_think.",
            file=sys.stderr,
        )
        return 1

    print(content)
    return 0


if __name__ == "__main__":
    sys.exit(main())
