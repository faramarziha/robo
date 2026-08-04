#!/bin/bash
# Test for WGDashboard.php functions

cd "$(dirname "$0")" || { echo "Failed to cd"; kill -9 $$; }

# Run the PHP test script for downloadconfig
php tests/test_downloadconfig.php
