#!/bin/bash
# Double-click on macOS to start a local web server and open the Flash promo.
cd "$(dirname "$0")"
PORT=8765
URL="http://localhost:${PORT}/index.html"
# Try Python 3 first, then Python 2.
if command -v python3 >/dev/null 2>&1; then
  ( sleep 1 && open "$URL" ) &
  python3 -m http.server "$PORT"
elif command -v python >/dev/null 2>&1; then
  ( sleep 1 && open "$URL" ) &
  python -m SimpleHTTPServer "$PORT"
else
  echo "Python is required to run the local server."
  echo "Install Python 3 (https://www.python.org/) and try again."
  read -n 1 -s -r -p "Press any key to exit..."
fi
