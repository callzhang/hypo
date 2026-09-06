# Hypo Documentation

This directory contains all documentation for the Hypo clipboard sync project.

## 📚 Documentation Structure

### Core Documentation
- **[PRD](prd.md)** - Product Requirements Document
- **[Technical Specification](technical.md)** - Complete technical documentation
- **[Protocol Specification](protocol.md)** - Message format and protocol details
- **[Architecture Diagram](architecture.mermaid)** - System architecture visualization
- **[Changelog](../changelog.md)** - Version history and project status summary

### User Documentation
- **[User Guide](USER_GUIDE.md)** - End-user documentation, including
  installation for each platform
- **[Troubleshooting](TROUBLESHOOTING.md)** - Common issues and solutions

### Per-Client Documentation
- **[Windows Client](../windows/README.md)** - What is implemented, how it is
  verified, and where it diverges from its design
- **[Verifying Windows](../windows/VERIFYING.md)** - What only a real Windows
  machine can answer, ordered by how likely each is to be broken

### Development Documentation
- **[Version Management](VERSION_MANAGEMENT.md)** - How versions are set and released
- **[Debugging Sync Issues](DEBUGGING_SYNC_ISSUES.md)** - Diagnosing sync failures
- **[Changelog](../changelog.md)** - Version history and project status

### Design and Research
- **[Specifications](superpowers/specs/)** - Design documents, annotated where the
  implementation diverged
- **[Research](research/)** - Historical research documents
  - [Cryptography Research](research/crypto_research.md) - Library evaluation (decision completed)

### Other
- **[Commercialization](COMMERCIALIZATION.md)** - Business considerations
- **[SMS Auto-Sync](prd.md)** - SMS sync feature (documented in the PRD)

## 🚀 Quick Start

1. **New to the project?** Start with [PRD](prd.md) and [Technical Specification](technical.md)
2. **Setting up?** See [User Guide](USER_GUIDE.md)
3. **Developing?** Read [Technical Specification](technical.md), then the client
   you are working on — [Windows](../windows/README.md), [macOS](../macos/),
   [Android](../android/README.md)
4. **Troubleshooting?** Check [Troubleshooting Guide](TROUBLESHOOTING.md)
5. **Version history?** See [Changelog](../changelog.md)

## 📝 Document Status

- ✅ **Complete** - Fully documented and up-to-date
- 🟡 **In Progress** - Being actively updated
- 🔴 **Outdated** - Needs review and update

Most core documentation is complete. Bug reports and research documents are maintained as needed.

