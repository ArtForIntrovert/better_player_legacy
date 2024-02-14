#!/usr/bin/env bash

fvm flutter analyze --no-fatal-infos --no-fatal-warnings --preamble > analysis_results.txt
HAS_ERRORS=$?

if [ $HAS_ERRORS != 0 ];
then
    sed -i -e 's/^/│ /' analysis_results.txt
    echo "┌────────"
    echo "│ Analysis errors:"
    cat analysis_results.txt | grep "error •"
    echo ""
    echo "└────────"
    
    rm analysis_results.txt
    exit $HAS_ERRORS
fi

rm analysis_results.txt
