// Day arithmetic on 'YYYY-MM-DD' strings. The engine works in whole days in
// the owner's timezone (settings.timezone); a Day is a calendar date, never an
// instant, so there is no DST to get wrong. Lexicographic order == date order.

export type Day = string;

const DAY_MS = 86_400_000;

export function isDay(s: unknown): s is Day {
  return typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
}

export function dayToUTC(day: Day): Date {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d));
}

export function utcToDay(d: Date): Day {
  return d.toISOString().slice(0, 10);
}

export function shiftDay(day: Day, n: number): Day {
  return utcToDay(new Date(dayToUTC(day).getTime() + n * DAY_MS));
}

/** b − a in whole days (negative when b is before a). */
export function daysBetween(a: Day, b: Day): number {
  return Math.round((dayToUTC(b).getTime() - dayToUTC(a).getTime()) / DAY_MS);
}

/** 0 = Monday … 6 = Sunday (CapacityModel is Monday-first). */
export function weekdayMondayFirst(day: Day): number {
  return (dayToUTC(day).getUTCDay() + 6) % 7;
}

export function minDay(...days: (Day | null | undefined)[]): Day | undefined {
  const xs = days.filter((d): d is Day => !!d);
  if (xs.length === 0) return undefined;
  return xs.reduce((a, b) => (a < b ? a : b));
}

/** Start of day for an instant, in the given IANA timezone, as a Day. */
export function todayIn(timeZone: string, now: Date = new Date()): Day {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "00";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

/** An ISO-8601 instant (or a Day) → the Day it falls on in `timeZone`. */
export function dayOf(iso: string | null | undefined, timeZone: string): Day | undefined {
  if (!iso) return undefined;
  if (isDay(iso)) return iso;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return undefined;
  return todayIn(timeZone, new Date(t));
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** Swift's "EEE MMM d": "Mon Nov 9". */
export function formatEEEMMMd(day: Day): string {
  const d = dayToUTC(day);
  return `${WEEKDAYS[d.getUTCDay()]} ${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`;
}

/** Python's "%a %b %d": "Mon Nov 09" (zero-padded). */
export function formatAbd(day: Day): string {
  const d = dayToUTC(day);
  return `${WEEKDAYS[d.getUTCDay()]} ${MONTHS[d.getUTCMonth()]} ${String(d.getUTCDate()).padStart(2, "0")}`;
}

/** 'YYYYMMDD' for iCalendar DATE values. */
export function compactDay(day: Day): string {
  return day.replace(/-/g, "");
}
