.PHONY: deploy validate delete

-include .env
export

deploy:
	monaco deploy manifest.yaml

validate:
	monaco deploy manifest.yaml --dry-run

delete:
	monaco delete --manifest manifest.yaml --file delete.yaml
