import type { ReactElement, SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement>;

function IconBase({ children, ...props }: IconProps): ReactElement {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...props}>
      {children}
    </svg>
  );
}

export const PowerIcon = (props: IconProps) => <IconBase {...props}><path d="M12 2.8v8.3"/><path d="M6.15 5.85a8 8 0 1 0 11.7 0"/></IconBase>;
export const LaptopIcon = (props: IconProps) => <IconBase {...props}><rect x="4" y="5" width="16" height="11" rx="1.6"/><path d="M2.8 19h18.4"/></IconBase>;
export const BackIcon = (props: IconProps) => <IconBase {...props}><path d="m14.8 5.5-6.5 6.5 6.5 6.5"/></IconBase>;
export const MenuIcon = (props: IconProps) => <IconBase {...props}><path d="M5 7h14M5 12h14M5 17h14"/></IconBase>;
export const HomeIcon = (props: IconProps) => <IconBase {...props}><path d="m4 10 8-6.4 8 6.4"/><path d="M6.5 9.5V20h11V9.5"/></IconBase>;
export const TVIcon = (props: IconProps) => <IconBase {...props}><rect x="3" y="6" width="18" height="13" rx="2"/><path d="m9 3 3 3 3-3"/></IconBase>;
export const VolumeUpIcon = (props: IconProps) => <IconBase {...props}><path d="M3.2 9.3h3.1l4.4-3.8v13l-4.4-3.8H3.2Z" fill="currentColor" stroke="none"/><path d="M17.4 8.5v7M13.9 12h7" strokeWidth="2.2"/></IconBase>;
export const VolumeDownIcon = (props: IconProps) => <IconBase {...props}><path d="M3.2 9.3h3.1l4.4-3.8v13l-4.4-3.8H3.2Z" fill="currentColor" stroke="none"/><path d="M13.9 12h7" strokeWidth="2.2"/></IconBase>;
export const MicrophoneIcon = (props: IconProps) => <IconBase {...props}><rect x="8" y="3" width="8" height="12" rx="4"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3M8.5 21h7"/></IconBase>;
export const ReturnIcon = (props: IconProps) => <IconBase {...props}><path d="M19 6v4.2a4 4 0 0 1-4 4H6"/><path d="m10 10-4 4 4 4" strokeWidth="2.2"/></IconBase>;
export const ChevronUp = (props: IconProps) => <IconBase {...props}><path d="m6 15 6-6 6 6"/></IconBase>;
export const ChevronDown = (props: IconProps) => <IconBase {...props}><path d="m6 9 6 6 6-6"/></IconBase>;
export const ChevronLeft = (props: IconProps) => <IconBase {...props}><path d="m15 6-6 6 6 6"/></IconBase>;
export const ChevronRight = (props: IconProps) => <IconBase {...props}><path d="m9 6 6 6-6 6"/></IconBase>;
