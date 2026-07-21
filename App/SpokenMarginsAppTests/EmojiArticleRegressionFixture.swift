import Foundation

enum EmojiArticleRegressionFixture {
    static let title = "Designing emoji for the way we communicate today"
    static let sourceURL = "https://blog.google/products-and-platforms/platforms/android/world-emoji-day-noto-3d/"
    static let malformedHTML = """
    <article>
      <p>The way we use emoji has changed. You sent a nail polish emoji (💅) because you were getting your nails polished.</p>
      <h2>Expression keeps evolving</h2>
      <p>We collapse, internally scream, laugh 😂, feel overwhelmed 😭, and roll on the floor laughing 🤣.</p>
      <h2>Art informs innovation</h2>
      <p>Have you looked closely at a real kangaroo? They’re terrifying 🙀.</p>
      <p>Designers test skin tones together 💪💪🏻💪🏼💪🏽💪🏾💪🏿 and preserve joined emoji such as 👨‍👩‍👧‍👦.</p>
      <video aria-label="A static thumbs up emoji" controls=""><source type="video/mp4" src="> Sorry, your browser doesn't support embedded videos, but don't worry, you can <a href=">download it</a> and watch it.</video>
      <script>window.crashTheReader = true</script>
      <style>body { display: none }</style>
      <h2>Language is for the people</h2>
      <p>Language only truly lives when we find new ways to use it. ⛲</p>
    </article>
    """
}
