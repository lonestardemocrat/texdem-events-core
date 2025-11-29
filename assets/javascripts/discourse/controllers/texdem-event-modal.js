import Controller from "@ember/controller";
import { action } from "@ember/object";

const DEFAULT_TIMEZONE = "America/Chicago";

function buildTimeForDateTag(startTime) {
  if (!startTime) {
    return "000000";
  }

  let time = startTime.trim().toUpperCase();

  const hasAM = time.endsWith("AM");
  const hasPM = time.endsWith("PM");

  if (hasAM || hasPM) {
    time = time.replace("AM", "").replace("PM", "").trim();
  }

  let [hourStr, minuteStr] = time.split(":");
  if (!minuteStr) {
    minuteStr = "00";
  }

  let hour = parseInt(hourStr, 10);
  let minute = parseInt(minuteStr, 10);

  if (isNaN(hour)) hour = 0;
  if (isNaN(minute)) minute = 0;

  if (hasAM) {
    if (hour === 12) {
      hour = 0;
    }
  } else if (hasPM) {
    if (hour !== 12) {
      hour += 12;
    }
  }

  const hh = String(hour).padStart(2, "0");
  const mm = String(minute).padStart(2, "0");

  return `${hh}${mm}00`;
}

export default class TexdemEventModalController extends Controller {
  date = "";
  startTime = "";
  timezone = DEFAULT_TIMEZONE;

  locationName = "";
  address = "";
  county = "";
  rsvpUrl = "";
  isPublic = true;

  @action
  insert() {
    const toolbarEvent = this.model?.toolbarEvent;
    if (!toolbarEvent || typeof toolbarEvent.addText !== "function") {
      this.send("closeModal");
      return;
    }

    const date = (this.date || "").trim();
    const startTime = (this.startTime || "").trim();
    const timezone = (this.timezone || DEFAULT_TIMEZONE).trim();

    if (!date || !startTime) {
      // bare-minimum guard; you can add nicer validation later
      alert("Please enter both a date and a start time.");
      return;
    }

    const locationName = (this.locationName || "").trim();
    const address = (this.address || "").trim();
    const county = (this.county || "").trim();
    const rsvpUrl = (this.rsvpUrl || "").trim();
    const isPublic = !!this.isPublic;

    const timeForTag = buildTimeForDateTag(startTime);
    const dateTagLine = `[date=${date} time=${timeForTag} timezone="${timezone}"]\n\n`;

    const countyLine = county ? `* **County:** ${county}\n` : "";
    const rsvpLine = rsvpUrl ? `* **RSVP link:** ${rsvpUrl}\n` : "";

    const visibilityLabel = isPublic ? "Public" : "Private";

    const detailsBlock =
      `**Event Details**\n` +
      `* **Date:** ${date}\n` +
      `* **Start time:** ${startTime}\n` +
      `* **Location name:** ${locationName}\n` +
      `* **Address:** ${address}\n` +
      countyLine +
      rsvpLine +
      `* **Visibility:** ${visibilityLabel}\n`;

    toolbarEvent.addText(`\n${dateTagLine}${detailsBlock}\n`);

    this.send("closeModal");
  }
}
