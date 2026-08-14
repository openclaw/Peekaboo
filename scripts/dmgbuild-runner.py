# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "dmgbuild==1.6.7",
#   "ds-store==1.3.3",
#   "mac-alias==2.2.3",
# ]
# ///
"""Locked entry point for Peekaboo's native Finder-layout generator."""

from dmgbuild.__main__ import main


if __name__ == "__main__":
    main()
