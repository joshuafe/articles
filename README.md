# Articles Firefox Extension

This repository contains a minimal Firefox extension that downloads the active tab as a PDF using metadata from Crossref to name the file.

## How it works

When you click the extension button, the URL of the current tab is treated as the PDF link. The extension queries [Crossref](https://api.crossref.org/) for metadata using any DOI found in the URL. The downloaded file is saved in the `Articles` folder of your browser downloads directory with a name of the form:

```
firstauthor-lastauthor-journal-year-title.pdf
```

If metadata cannot be retrieved, placeholder values are used.

## Installation

1. Open Firefox and navigate to `about:debugging#/runtime/this-firefox`.
2. Click **Load Temporary Add-on** and select the `manifest.json` file in the `firefox-extension` directory.
3. Navigate to a PDF page and click the extension icon to download the file.
