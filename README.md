# SBrandsborg Minecraft ATM 10 Server

This repository contains a small website used to show the status of the **All the Mods 10** Minecraft server run by `sbrandsborg`.

## Contents

- `index.html` – Landing page with basic server information such as uptime and rules. The page fetches live data from [mcsrvstat.us](https://api.mcsrvstat.us/) to display whether the server is online and how many players are connected.
- `stats.html` – Extended statistics page. It loads data from `Get-MCStats.json` and summarises player activity like chests looted, items inserted, mob kills and more.
- `Get-MCStats.json` – JSON dump of the latest server statistics. This file is automatically updated at regular intervals.

## Viewing the Pages

Open the HTML files directly in your browser or serve them from a web server. They are designed to work with GitHub Pages if you want to host them online.

```bash
# Example using Python's built‑in web server
python3 -m http.server
```

Then browse to `http://localhost:8000/index.html` or `stats.html`.

## Customising

If you are running your own server, edit the IP address in `index.html` so the status check points to your host. The layout can be adjusted with regular HTML and CSS.

## License

This repository was created for a private Minecraft server and does not include any code with a specific license. Use and modify the files as you see fit.
