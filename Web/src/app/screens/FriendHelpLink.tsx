// "Get help" under a card where a friend's link got stuck (#5268): the site's friends page in a new tab, at the
// card's question, so this tab stays as it was. Underlined, so it never reads as a link by colour alone.
import { FRIEND_HELP_WORDS, friendHelpHref, type FriendHelpTopic } from '../logic/friend-help.ts';

export function FriendHelpLink({ topic, text = FRIEND_HELP_WORDS.get }: { topic?: FriendHelpTopic; text?: string }) {
  return (
    <p>
      <a className="help-link" href={friendHelpHref(topic)} target="_blank" rel="noopener noreferrer">
        {text}
      </a>
    </p>
  );
}
