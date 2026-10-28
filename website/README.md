# orbtchess.org

The project website: plain static HTML, one stylesheet and one small script in `public/`, no
build step. It is hosted on Cloudflare Pages (free plan), uploaded from the command line.

## Deploy

    website/deploy.sh            # production: orbtchess.org
    website/deploy.sh preview    # preview URL only, production untouched

The script runs `wrangler pages deploy public` (wrangler through `npx`, needs Node).

Once, before the first deploy:

    npx wrangler@4 login
    npx wrangler@4 pages project create orbtchess --production-branch=main

Then add the custom domain `orbtchess.org` in the Cloudflare dashboard (Workers & Pages ›
orbtchess › Custom domains).

## Files

- Each page is `<path>/index.html`, so the paths the app links to (`/`, `/support`, `/privacy`)
  work without rewrite rules. Keep them.
- `404.html` is served for missing pages.
- `assets/icon.png` and `assets/apple-touch-icon.png` are exported from `apple/ORBT/AppIcon.icon`
  with `ictool` (see `CLAUDE.md`); `assets/favicon.svg` is `Design/AppIcon-light.svg`.
- `assets/screens/` are simulator screenshots (iPhone 16e and iPad Pro 13-inch (M5), iOS 26.2,
  status bar at 9:41), each in `-light` and `-dark`, picked by the browser's color scheme
  (`<picture>`), resized and saved as WebP (`cwebp -q 84`). The repertoires shown are sample
  ones (Italian Game, Najdorf, Queen's Gambit Declined), not anyone's own.
- `assets/app-store-badge.svg` is Apple's official badge
  (developer.apple.com/app-store/marketing/guidelines); its link is `#` until the app is live.
- Header and footer are repeated in each page; change them in all of them.
- Motion: scroll-driven CSS animations (`animation-timeline`) that only move things, never hide
  them, and `assets/site.js`, which pins a phone beside "How it works" on wide screens. Without
  the script, or on phones, each step shows its own screenshot. All off with reduced motion.
- Colors come from the app: its icon's indigo, its blue tint, its board squares and its meaning
  colors (`Design/COLORS.md`).

## Preview locally

    python3 -m http.server -d website/public 8000
