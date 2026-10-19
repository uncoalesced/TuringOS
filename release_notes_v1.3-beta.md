# TuringOS v1.3-beta Unified Release

Welcome to the **v1.3-beta** unified release of **TuringOS** and **TuringOS Bazaar**.
This release consolidates upstream architectural improvements, establishes out-of-the-box persistent user mode, aligns window and screen framing with the renewed brand palette, and establishes the release benchmark qualification system.

### Key Highlights

#### 1. Out-of-the-Box Persistent User Mode
- **Live Boot with Persistence by Default:** Configured the kernel command line with `--bootappend-live "boot=live components quiet splash persistence"`. The system automatically binds to any persistent overlay storage (`persistence.conf` with `/ union`), preserving user state, Claude Code authentication, and installed MCP packages across reboots without requiring ephemeral RAM mode.
- **Calamares Persistent User Autologin:** Hardened the post-install installer shell hook (`0495-installer.hook.chroot`) to dynamically resolve the real non-root UID 1000 user created during installation, cleanly transferring LightDM autologin and Homebrew ownership to the persistent user upon disk install.
- **Boot Menu Deduplication:** Enhanced isolinux and GRUB boot menu cloning hooks to avoid redundant command-line parameters.

#### 2. Renewed Brand Palette & Window Borders
- **Visual Identity:** Window framing, borders, and UI accents aligned with the renewed brand palette (`assets/pallete/renewed_palette.jpg`).
- **Hyprland Window Borders:** Active window borders updated to the fiery brand gradient (`rgb(e85002) rgb(f16001) 45deg`), inactive borders styled with Dark Gray (`rgb(333333)`), and deep black shadow base (`rgba(000000ee)`).
- **Web UI Tokens:** Exported design tokens (`--tos-brand-orange: #e85002`, `--tos-primary-bg: #000000`, `--tos-dark-gray: #333333`, `--tos-gray: #646464`, etc.) into `ui/web/css/tokens.css` with active in-shell app window focus framing in `app-window.css`.

#### 3. Bazaar Cryptographic & Offline Security Model
- **Ed25519 Index Verification:** Cryptographic signature verification using minisign/Ed25519 with bundled trust anchors.
- **24-Hour Offline Caching & Fallbacks:** High-reliability caching and fallback to bundled offline catalogue when network is unavailable.
- **Per-Project Isolation:** Project-scoped enable/disable rules synchronized with `.claude/settings.json`.

#### 4. Automated Release Benchmark Suite (`tests/benchmark.sh`)
- Introduced `tests/benchmark.sh` as the automated qualification benchmark for every release.
- Validates window manager fallback, bootloader persistence deduplication, Bazaar 10-step cryptographic integrity, daemon compilation, visual border token compliance, and installer autologin hardening.
- Exports structured reports to `benchmark_report.json` with execution latency tracking.

---

### Downloads & ISO Artifacts

| Architecture | Image Name | Size | SHA-256 Checksum |
| :--- | :--- | :--- | :--- |
| **x86_64 / amd64** | `turingos-amd64.hybrid.iso` (alias: `turningos-amd64.hybrid.iso`) | 1.85 GB (1,851,359,232 bytes) | `579878f9455d80158f1a387ee806c463065bb275e35b9bfdf573e2568014da2e` |
| **aarch64 / arm64** | `turingos-arm64.hybrid.iso` (alias: `turningos-arm64.hybrid.iso`) | 1.67 GB (1,671,168,000 bytes) | `fcdafc1edcb958417cceff77a6f651c6f87d66ebfb152b1df4e913d11465b936` |

*Engineered by uncoalesced*
