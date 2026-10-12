# Security Policy

## Reporting a Vulnerability

Please do not report security vulnerabilities through public GitHub issues.

If you believe you have found a security vulnerability in this repository (for example, in the OpenPipeline configuration, the custom alert templates, or the sample runners), report it through Dynatrace's responsible disclosure process described on the [Dynatrace Trust Center](https://www.dynatrace.com/company/trust-center/security/).

Include as much detail as you can: the file or configuration affected, the steps to reproduce, and the potential impact. You should receive an acknowledgment of your report within a reasonable time; please allow time for the issue to be investigated before any public disclosure.

## Supported Versions

This repository ships configuration-as-code (Monaco) and sample runner code, not a running service with its own release train. Security fixes are applied to the `main` branch. There are no separately maintained older versions.

| Branch | Supported |
| --- | --- |
| `main` | ✅ |
| older branches | ❌ |

## Scope

This security policy covers:

- Monaco configuration files (`monaco/`)
- Sample runner code (`samples/`)
- Documentation (`docs/`)

It does not cover vulnerabilities in third-party tools or services (Monaco CLI, Dynatrace platform, Playwright, k6) that this repository depends on. Report those to the respective upstream projects.
