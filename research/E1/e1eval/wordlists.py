"""Word lists and patterns shared by both baselines. Everything here ships as data on the phone."""
import re

STOP = set("""a an the and or but if so then than that this these those it its it's i me my we our you your he
him his she her they them their there here what which who whom whose when where why how is are was were be been
being am do does did done have has had having will would can could should shall may might must not no yes of in on
at to for from by with about as into over under up down out off just really very pretty also too like actually
basically honestly literally again still even all any some more most much many lot lots one ones thing things
stuff way something anything everything kind sort bit oh ha yeah okay ok well right wait now say says said get got
go going gonna make makes made think know mean means sound sounds seem seems feel feels let lets 's n't 're 've 'll 'm""".split())

TODO_VERBS = set("""look find read send share email check add write watch get sign go ask remind buy listen call
text try download bookmark follow subscribe order book message ping tell show print note""".split())
TODO_RE = re.compile(r"\b(note to self|i (need|have|want|ought) to|i should|remind me|remember to|to ?do\b|gotta)\b")

WH_AUX = set("""who what when where why how which whose whom is are was were do does did can could will would should
has have had isn't aren't didn't doesn't won't wouldn't""".split())
QUESTION_RE = re.compile(r"\?|\bi wonder\b|\bi'm not sure (if|whether|what|why|how)\b")

QUOTE_RE = re.compile(r"[\"“”]|\b(save (that|this) (line|quote)|(that|what a|love that) (line|quote)|quote:)")

CONNECTION_RE = re.compile(
    r"\b(remind(s|ed)? me|same (thing|story|point|argument|feeling|idea|as)|just like|exactly like|like my|"
    r"when i\b|i (read|did|had|moved|used to|remember|once|tried)\b|"
    r"(my|our) (partner|team|grandfather|grandmother|dad|mom|mother|father|wife|husband|friend|university|job|"
    r"kid|kids|son|daughter|brother|sister|boss|house|balcony|office|company|class)\b|"
    r"we (applied|did|used|had|tried)\b|(the|that) other episode|another episode|at work\b|in college\b)")

REACTION_WORDS = set("""wow ha haha lol love loved cool amazing awesome great nice grim sad bittersweet contagious
incredible crazy wild beautiful fascinating funny hilarious laugh brilliant perfect sweet yikes whoa oof ugh glad
imagine""".split())
REASONING_RE = re.compile(r"\b(because|since|so that|means|is why|should|probably|explains|shows|which is)\b")

ITEM_RE = re.compile(r"\b(this|the) (whole )?(episode|article|podcast|show|piece|interview|essay|book)\b|\bthis one\b")
NONE_RE = re.compile(r"\bnote to self\b")
FOLLOW_CUE_RE = re.compile(r"^(oh|so|again|actually|update|answer|answered|he just|she just|they just)\b")

# Named things with no Apple NaturalLanguage name type.
CELESTIAL_PLACES = {"moon", "mars", "earth", "venus", "jupiter", "saturn", "mercury", "sun", "pluto"}
ACRONYM_RE = re.compile(r"\b[A-Z][A-Za-z]*[A-Z]{1,}[A-Za-z]*\b")
TOPIC_STOP = STOP | set("""episode article part time people person host guy guys day days year years question
answer point case idea sense answer lot end way thing number word words line""".split())

# Acronyms that are common nouns, not names.
COMMON_ACRONYMS = {"AI", "VR", "AR", "EVA", "EVAs", "UV", "MRI", "CEO", "CTO", "GPS", "TV", "PDF", "FAQ", "DNA",
                   "OK", "PhD", "USB", "API", "ML", "LLM", "IQ", "ID", "DIY", "ASAP", "FYI", "PR"}
CALENDAR = set("""january february march april may june july august september october november december
monday tuesday wednesday thursday friday saturday sunday today tomorrow yesterday""".split())
WORK_NOUNS = r"(?:episode|book|books|movie|film|show|podcast|piece|article|novel|paper|documentary|essay|album|series)"
WORK_VERBS = r"(?:read|watch|rewatch|listen to|finish|reading|watching)"
