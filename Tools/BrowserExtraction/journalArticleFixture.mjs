// Test support, not shipped. The shape of a journal essay page that dropped its
// body on import (#796): one <article> holding the essay in a container whose
// class ends in "-ad" (publishers use "--with-ad" for "this body carries an
// ad slot"), then a block of footnotes, then the Category / Subject details,
// dedication and author bio. The prose is placeholder text; only the structure
// is the publisher's. Contracts/fixtures/chapters/journal-footnotes-block.md is
// what a correct capture of this page reads like.

function prose(topic, sentences = 4) {
  return Array.from({ length: sentences }, (_, index) =>
    `This is sentence ${index + 1} of a paragraph about ${topic}, written as placeholder prose so the page has the weight of a real essay.`
  ).join(" ");
}

export const JOURNAL_SECTIONS = [
  "First Placeholder Section",
  "Second Placeholder Section",
  "Third Placeholder Section",
  "Fourth Placeholder Section"
];

export const JOURNAL_BYLINE = "Jordan Example";

export function journalArticleBody({ bodyClass = "article__body article__body--with-ad" } = {}) {
  const section = (title, topic) => `<h2>${title}</h2>
      <p>${prose(topic)}</p><p>${prose(`${topic}, continued`)}</p><p>${prose(`${topic}, again`)}</p>`;
  const footnotes = Array.from({ length: 5 }, (_, index) =>
    `<div class="article__footnote">${index + 1} Placeholder Author, Placeholder Title ${index + 1} (Placeholder Press, 2017), ${10 + index}.</div>`
  ).join("");
  return `<div class="overlayer journal-article-single"><article class="journalarticle">
    <div class="article__header article__header--journal">
      <div class="header header--scrollable"><div class="header__inner"><div>Example Journal</div><div>Subscribe</div></div></div>
      <div class="article__header-top">
        <h1 class="article__header-title">A Placeholder Essay on Placeholder Labor</h1>
        <h2 class="article__header-authors">${JOURNAL_BYLINE}</h2>
      </div>
      <div class="article__header-media"><div class="article__header-media-caption"><p>A caption for the lead image.</p></div></div>
    </div>
    <div class="article__content">
      <div class="journalarticle__date-wrap"><div class="journalarticle__project"><strong>Example Series</strong></div><div class="journalarticle__date">September 2017</div></div>
      <div class="${bodyClass}"><span class="js-unwrap">
        <p>${prose("the opening argument")}</p><p>${prose("the opening argument, continued")}</p><p>${prose("the aim of the essay")}</p>
        ${section(JOURNAL_SECTIONS[0], "the first section")}
      </span><div class="inline-carousel"><p>A model house. Image: Placeholder Museum.</p></div><span class="js-unwrap">
        ${section(JOURNAL_SECTIONS[1], "the second section")}
        ${section(JOURNAL_SECTIONS[2], "the third section")}
      </span><span class="js-unwrap">
        ${section(JOURNAL_SECTIONS[3], "the fourth section")}
      </span></div>
      <div class="article__footnotes">
        <div class="article__footnotes-title">Notes</div>
        <div class="article__footnotes-wrap">${footnotes}</div>
      </div>
      <div class="article__bottom">
        <div class="article__bottom-details">
          <div class="article__bottom-details-list-wrap"><h6>Category</h6><div class="article__bottom-details-list"><span><a href="/search?c[]=One">Placeholder One</a>, </span><span><a href="/search?c[]=Two">Placeholder Two</a></span></div></div>
          <div class="article__bottom-details-list-wrap"><h6>Subject</h6><div class="article__bottom-details-list"><span><a href="/search?s[]=One">Placeholder Subject</a></span></div></div>
          <div class="article__bottom-details-list-wrap"><a class="sidebar-return-issue" href="/series">Return to <strong>Example Series</strong></a></div>
          <ul class="article__bottom-buttons"><li><a class="button" href="/files/essay.pdf">PDF</a></li></ul>
        </div>
        <div class="article__bottom-credits">
          <p><em>This essay is dedicated to the memory of a placeholder colleague. It is also dedicated to looking after ourselves and each other.</em></p>
          <p><em>Example Series is a collaborative project between a placeholder journal and a placeholder museum.</em></p>
          <p><strong>${JOURNAL_BYLINE}</strong> is a placeholder professor of placeholder studies. Placeholder books include <em>A Placeholder Book</em> (Placeholder Press, 2014).</p>
        </div>
      </div>
      <div class="journalarticle__copyright">© 2017 Example Journal and the author</div>
    </div>
  </article></div>`;
}
