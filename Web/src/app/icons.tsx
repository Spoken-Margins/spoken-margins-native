// Line icons drawn for this app, 24-unit grid, currentColor. Every icon sits beside a text label or inside
// a control with an accessible name; none carries meaning alone.
import type { ReactNode } from 'react';

function Icon({ children, size = 24 }: { children: ReactNode; size?: number }) {
  return (
    <svg className="icon" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      {children}
    </svg>
  );
}

// The four tabs follow the SF Symbols the iPhone app's tab bar uses (#3040): books.vertical,
// dot.radiowaves.left.and.right, quote.bubble and gearshape.
export const LibraryIcon = () => (
  <Icon>
    <rect x="3" y="4" width="4.2" height="16" rx="1" />
    <rect x="9.2" y="4" width="4.2" height="16" rx="1" />
    <path d="M15.4 5.6l3.9-1.1 3.4 14.9-3.9 1.1z" />
  </Icon>
);
export const FollowingIcon = () => (
  <Icon>
    <circle cx="12" cy="12" r="1.9" fill="currentColor" stroke="none" />
    <path d="M8.6 8.6a4.8 4.8 0 0 0 0 6.8M15.4 8.6a4.8 4.8 0 0 1 0 6.8" />
    <path d="M5.5 5.5a9.2 9.2 0 0 0 0 13M18.5 5.5a9.2 9.2 0 0 1 0 13" />
  </Icon>
);
export const MarginsIcon = () => (
  <Icon>
    <path d="M5 4.5h14a2 2 0 0 1 2 2v8.5a2 2 0 0 1-2 2h-7.5L7 20.5V17H5a2 2 0 0 1-2-2V6.5a2 2 0 0 1 2-2z" />
    <path d="M9.6 8.6l-1 3.2M13.4 8.6l-1 3.2" strokeWidth="2.2" />
  </Icon>
);
export const SettingsIcon = () => (
  <Icon>
    <circle cx="12" cy="12" r="6.4" />
    <circle cx="12" cy="12" r="2.4" />
    <path
      d="M12 2.6v3M12 18.4v3M2.6 12h3M18.4 12h3M5.35 5.35l2.1 2.1M16.55 16.55l2.1 2.1M5.35 18.65l2.1-2.1M16.55 7.45l2.1-2.1"
      strokeWidth="2.6"
      strokeLinecap="butt"
    />
  </Icon>
);
export const PlayIcon = ({ size }: { size?: number }) => (
  <Icon size={size}>
    <path d="M8 5.5v13l10.5-6.5z" fill="currentColor" />
  </Icon>
);
export const PauseIcon = ({ size }: { size?: number }) => (
  <Icon size={size}>
    <path d="M8 5.5v13M16 5.5v13" strokeWidth="3.2" />
  </Icon>
);
export const BackIcon = () => (
  <Icon>
    <path d="M4 12a8 8 0 1 0 2.4-5.7M4 4v4h4" />
    <text x="12" y="15.2" textAnchor="middle" fontSize="7.5" fill="currentColor" stroke="none" fontWeight="700">15</text>
  </Icon>
);
export const ForwardIcon = () => (
  <Icon>
    <path d="M20 12a8 8 0 1 1-2.4-5.7M20 4v4h-4" />
    <text x="12" y="15.2" textAnchor="middle" fontSize="7.5" fill="currentColor" stroke="none" fontWeight="700">15</text>
  </Icon>
);
export const PenIcon = () => (
  <Icon>
    <path d="M4 20h4L19 9l-4-4L4 16z" />
    <path d="M13.5 6.5l4 4" />
  </Icon>
);
export const MicIcon = () => (
  <Icon>
    <rect x="9" y="3" width="6" height="11" rx="3" />
    <path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21" />
  </Icon>
);
export const StopIcon = () => (
  <Icon>
    <rect x="6.5" y="6.5" width="11" height="11" rx="2" fill="currentColor" />
  </Icon>
);
export const PlusIcon = () => (
  <Icon>
    <path d="M12 5v14M5 12h14" />
  </Icon>
);
export const RefreshIcon = () => (
  <Icon>
    <path d="M20 12a8 8 0 1 1-2.34-5.66" />
    <path d="M20 4v5h-5" />
  </Icon>
);
export const ChevronIcon = () => (
  <Icon>
    <path d="M9 5l7 7-7 7" />
  </Icon>
);
export const DownIcon = () => (
  <Icon>
    <path d="M5 9l7 7 7-7" />
  </Icon>
);
export const CloseIcon = () => (
  <Icon>
    <path d="M6 6l12 12M18 6L6 18" />
  </Icon>
);
export const DownloadIcon = () => (
  <Icon>
    <path d="M12 4v11M7.5 10.5L12 15l4.5-4.5" />
    <path d="M5 19h14" />
  </Icon>
);
export const ShareIcon = () => (
  <Icon>
    <path d="M12 15V4M8 7.5L12 4l4 3.5" />
    <path d="M7 11H5.5v9h13v-9H17" />
  </Icon>
);
