# Contributing

Thanks for considering a contribution to this project. Issues and pull requests are welcome.

## Reporting issues

Before opening an issue, search existing issues to avoid duplicates. When reporting a bug, include:

- What you expected to happen and what happened instead
- The Monaco version (`monaco version`) and the relevant config file
- Any error output from `make validate` or `make deploy`

## Development setup

```bash
# Install Monaco CLI:
# See https://docs.dynatrace.com/docs/deliver/configuration-as-code/monaco

export DT_TENANT_URL=https://<your-sandbox-tenant>.apps.dynatrace.com
export PLATFORM_TOKEN=<your-token>

# Validate configs without deploying:
make validate

# Deploy to a sandbox environment:
make deploy

# Send a test event to verify the pipeline end to end:
./samples/basic-example.sh

# Clean up everything you deployed:
make delete
```

Use a sandbox tenant, not a production one — `make deploy` creates real OpenPipeline configuration, custom alerts, and dashboards.

## Making a change

1. Fork the repository and create a branch for your change.
2. Run `make validate` — it must pass before you deploy.
3. Deploy to a sandbox tenant and confirm the change works with a real test event, not just `make validate`. Configuration-as-code can pass validation and still fail to produce the metric, alert, or dashboard tile you intended.
4. If you touched `docs/get-started.md` or `docs/reference.md`, check that file paths, field names, and parameter names you reference still match the actual config — these have drifted from the code before.
5. Open a pull request describing what changed and why, and what you tested it against.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold it.
