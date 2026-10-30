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

export const LibraryIcon = () => (
  <Icon>
    <path d="M5 4v16M9.5 4v16" />
    <path d="M14 5.2l3.6-1 3.4 15.6-3.6 1z" />
  </Icon>
);
export const FollowingIcon = () => (
  <Icon>
    <path d="M4 11a9 9 0 0 1 9 9M4 5a15 15 0 0 1 15 15" />
    <circle cx="5" cy="19" r="1.4" fill="currentColor" stroke="none" />
  </Icon>
);
export const MarginsIcon = () => (
  <Icon>
    <path d="M6 4v16" strokeWidth="2.6" />
    <path d="M10.5 7h8M10.5 12h8M10.5 17h5" />
  </Icon>
);
export const SettingsIcon = () => (
  <Icon>
    <path d="M4 7h9M17 7h3M4 17h3M11 17h9" />
    <circle cx="15" cy="7" r="2" />
    <circle cx="9" cy="17" r="2" />
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
