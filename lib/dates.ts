export function localDateBoundary(reference: Date, timeZone: string, dayOffset: number) {
  const calendar = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(reference);
  const values = Object.fromEntries(calendar.map((part) => [part.type, part.value]));
  const target = new Date(Date.UTC(
    Number(values.year),
    Number(values.month) - 1,
    Number(values.day) + dayOffset,
  ));
  const targetAsUtc = target.getTime();
  let candidate = targetAsUtc;

  for (let attempt = 0; attempt < 3; attempt += 1) {
    const zoned = new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date(candidate));
    const parts = Object.fromEntries(zoned.map((part) => [part.type, part.value]));
    const asUtc = Date.UTC(
      Number(parts.year), Number(parts.month) - 1, Number(parts.day),
      Number(parts.hour), Number(parts.minute), Number(parts.second),
    );
    candidate += targetAsUtc - asUtc;
  }

  return new Date(candidate).toISOString();
}

export function parseLocalDateTime(value: string, timeZone: string) {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(value);
  if (!match) return null;
  const [, year, month, day, hour, minute] = match.map(Number);
  const targetAsUtc = Date.UTC(year, month - 1, day, hour, minute);
  const calendar = new Date(targetAsUtc);
  if (calendar.getUTCFullYear() !== year || calendar.getUTCMonth() !== month - 1 || calendar.getUTCDate() !== day) return null;
  let candidate = targetAsUtc;

  for (let attempt = 0; attempt < 3; attempt += 1) {
    const zoned = new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date(candidate));
    const parts = Object.fromEntries(zoned.map((part) => [part.type, part.value]));
    candidate += targetAsUtc - Date.UTC(
      Number(parts.year), Number(parts.month) - 1, Number(parts.day),
      Number(parts.hour), Number(parts.minute),
    );
  }
  const finalParts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(candidate));
  const final = Object.fromEntries(finalParts.map((part) => [part.type, part.value]));
  if (Number(final.year) !== year || Number(final.month) !== month || Number(final.day) !== day
    || Number(final.hour) !== hour || Number(final.minute) !== minute) return null;
  return new Date(candidate);
}

export function formatLocalDateTime(reference: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(reference);
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}T${value.hour}:${value.minute}`;
}

export function formatLocalDate(reference: Date, timeZone: string) {
  return formatLocalDateTime(reference, timeZone).slice(0, 10);
}
