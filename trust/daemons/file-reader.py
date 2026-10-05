#!/usr/bin/env python3
import sys


def main():
    if len(sys.argv) < 2:
        print("usage: file-reader <path>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    try:
        with open(path, "r") as f:
            print(f.read(), end="")
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
