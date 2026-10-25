#!/bin/zsh
set -u
SCRIPT_DIR="${0:A:h}"
zsh "$SCRIPT_DIR/publish_to_github.sh"
RESULT=$?
print ""
if [[ $RESULT -ne 0 ]]; then
  print "Publishing stopped. Review the message above; no different GitHub account was used."
fi
read -r "?Press Return to close this window. "
exit "$RESULT"
