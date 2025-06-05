async function fetchMetadata(url) {
  const doi = extractDoi(url);
  if (!doi) return defaultMeta();
  try {
    const resp = await fetch('https://api.crossref.org/works/' + encodeURIComponent(doi));
    if (!resp.ok) return defaultMeta();
    const data = await resp.json();
    const item = data.message;
    const authors = item.author || [];
    const firstAuthor = authors[0] ? authors[0].family || authors[0].given : 'unknown';
    const lastAuthor = authors.length > 1 ? (authors[authors.length - 1].family || authors[authors.length - 1].given) : firstAuthor;
    const journal = (item['container-title'] && item['container-title'][0]) || 'journal';
    const year = (item.issued && item.issued['date-parts'] && item.issued['date-parts'][0][0]) || 'year';
    const title = (item.title && item.title[0]) || 'title';
    return { firstAuthor, lastAuthor, journal, year, title };
  } catch (e) {
    console.error('metadata fetch failed', e);
    return defaultMeta();
  }
}

function extractDoi(url) {
  const match = url.match(/10\.\d{4,9}\/[^#?&]+/);
  return match ? match[0] : null;
}

function buildFileName(meta) {
  const sanitize = str => str.replace(/[^a-z0-9]+/gi, '_').replace(/^_+|_+$/g, '');
  return [meta.firstAuthor, meta.lastAuthor, meta.journal, meta.year, meta.title]
    .map(sanitize)
    .join('-');
}

function defaultMeta() {
  return { firstAuthor: 'first', lastAuthor: 'last', journal: 'journal', year: 'year', title: 'title' };
}

browser.browserAction.onClicked.addListener(async () => {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  const tab = tabs[0];
  if (!tab || !tab.url) return;
  const pdfUrl = tab.url;
  const meta = await fetchMetadata(pdfUrl);
  const fileName = buildFileName(meta) + '.pdf';
  try {
    await browser.downloads.download({
      url: pdfUrl,
      filename: 'Articles/' + fileName,
      conflictAction: 'uniquify'
    });
  } catch (e) {
    console.error('download failed', e);
  }
});
