# Justfile for The Guild

# Run guild-hall TUI
hall:
    cd guild-hall && bun run guild-hall.tsx

# Run conclave scanner
scan *ARGS:
    ./conclave.sh {{ARGS}}

# Install guild-hall dependencies
install-hall:
    cd guild-hall && bun install

# Run guild-hall tests
test-hall:
    cd guild-hall && bun test

# Typecheck guild-hall
check-hall:
    cd guild-hall && bun run typecheck
