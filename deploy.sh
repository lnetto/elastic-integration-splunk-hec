#!/bin/bash
set -e
source .env
elastic-package lint
elastic-package build
elastic-package install --zip build/packages/splunk_hec-0.1.0.zip
