# GhostPen website

The production website is built from `site/content/`, `site/layouts/`, and
`site/assets/` using Zine 0.14.0. The homepage is `site/layouts/home.shtml`.

From the repository root, start Zine's live development server:

```sh
zine
```

Open http://localhost:1990/GhostPen/. Zine watches the site files and reloads
the page after edits. To use another port, run `zine --port 1991`.

To build the static site locally, run `zine release -f`. The generated output
is in `public/`. The Pages workflow runs `zine release` on a clean checkout.
