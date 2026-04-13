# HyprFM Framework

If you've run a serious FiveM RP server, you've hit the wall. A player dupes their inventory because two requests fired at the same time. Someone crashes the server and three minutes of economy activity vanishes. A cheat menu calls a Lua export directly and spawns weapons out of thin air. These aren't edge cases — they're structural problems with how traditional frameworks are built. ESX and QBCore put Lua in charge of game state. Lua is not a database. HyprFM fixes this at the architecture level, not with patches.

## 🏗 Architecture

-   **State Engine:** SpacetimeDB (Rust) - Handles all relational data and real-time logic.
-   **Sidecar:** .NET / C# - Provides the bridge between the FiveM client/server and the state engine.
-   **Frontend:** React 18, TypeScript, and Zustand - A modern, high-performance UI (NUI) layer.
-   **Philosophy:** High-performance, "ready-to-go" out of the box, inspired by the development standards of popular RP servers such as Prodigy RP and NoPixel

## 📁 Project Structure

```text
HyprFm/
├── stdb-modules/          # Rust logic for SpacetimeDB (Inventory, Characters, Vehicles, etc.)
├── stdb-sidecar/          # .NET bridge and FiveM resource logic
├── fivem-server-files/    # FiveM server resources
└── FivemSTDBProject.sln   # Visual Studio Solution
```

## 🛠 Prerequisites

To develop or host HyprFM, you must have the following installed:

### Development Environment
-   **Rust Toolchain:** [rustup.rs](https://rustup.rs/) (Target: `wasm32-unknown-unknown`)
-   **SpacetimeDB CLI:** Version **2.0.3**
-   **Node.js & npm:** (LTS Version) for React NUI development
-   **Visual Studio 2022 / VS Code:** With .NET SDK and C# Dev Kit

### Server Environment
-   **FXServer Artifacts:** Latest recommended Windows/Linux artifacts
-   **SpacetimeDB Server:** Running instance (Local or Remote)

## 🚀 Getting Started

1.  **Clone the Repository**
    ```bash
    git clone https://github.com/Zerxis6543/HyprFm.git
    cd HyprFm
    ```

2.  **Initialize the State Engine**
    Navigate to the Rust modules and publish to your SpacetimeDB instance:
    ```bash
    cd stdb-modules
    spacetime publish --project-name hyprfm
    ```

3.  **Build the NUI**
    Install dependencies and build the React production files:
    ```bash
    cd ../fivem-server-files/resources/[core]/stdb-inventory/web
    npm install
    npm run build
    ```

4.  **Launch the Server**
    Open `FivemSTDBProject.sln` in Visual Studio to compile the sidecar, then start your FXServer via `txAdmin`.


## 📄 License & Usage

HyprFM follows an **Open-Core** model. The base architecture and essential systems are free for adoption. Advanced modules and pre-configured RP experiences are available via the tiered subscription model.
