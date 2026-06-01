"""Minimal entrypoint for the marketplace test app.

Imports application_sdk so the dependency is exercised at runtime and is
unambiguously part of the built image (which Snyk scans).
"""

import application_sdk


def main() -> None:
    print(f"adsd app started; application_sdk loaded from {application_sdk.__file__}")


if __name__ == "__main__":
    main()
