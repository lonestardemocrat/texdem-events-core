import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { inject as service } from "@ember/service";

const DEFAULT_TIMEZONE = "America/Chicago";

export default class InsertTexdemEvent extends Component {
  @service modal;
  @service composer;

  // Tracked fields for the form
  @tracked date = "2025-12-09";
  @tracked time = "18:00";
  @tracked locationName = "";
  @tracked address = "";
  @tracked county = "";
  @tracked rsvpLink = "";
  @tracked isPublic = true;
  @tracked timezone = DEFAULT_TIMEZONE;

  // Used for validation or initial data setup if needed
  constructor() {
    super(...arguments);
    // You could initialize the date to today's date here if preferred
  }

  // Define the actual content of the modal using Glimmer's template syntax
  <template>
    <div class="modal-body">
      <h2>TexDem Event Details</h2>
      <p>Enter the required information for your event.</p>

      <div class="control-group">
        <label>Date</label>
        <Input @type="date" @value={{this.date}} />
      </div>

      <div class="control-group">
        <label>Time</label>
        <Input @type="time" @value={{this.time}} />
      </div>

      <div class="control-group">
        <label>Timezone</label>
        {{! For a full dropdown, you'd need the TimezoneSelector component, but this is a placeholder Input }}
        <Input @type="text" @value={{this.timezone}} />
      </div>

      <hr>

      <div class="control-group">
        <label>Location Name</label>
        <Input @type="text" @value={{this.locationName}} />
      </div>

      <div class="control-group">
        <label>Address</label>
        <Input @type="text" @value={{this.address}} />
      </div>

      <div class="control-group">
        <label>County</label>
        <Input @type="text" @value={{this.county}} />
      </div>
      
      <div class="control-group">
        <label>RSVP Link</label>
        <Input @type="url" @value={{this.rsvpLink}} />
      </div>
      
      <div class="control-group">
        <label>
          <Input @type="checkbox" @checked={{this.isPublic}} />
          Visible to external API (Public)
        </label>
      </div>
    </div>

    <div class="modal-footer">
      <DButton @action={{this.insertSnippet}} @label="Insert Event" @class="btn-primary" />
      <DButton @action={{this.closeModal}} @label="Cancel" />
    </div>
  </template>

  @action
  insertSnippet() {
    // Format time for the [date=...] shortcode (HHmmss format)
    const shortcodeTime = this.time.replace(":", "") + "00"; 
    
    // Construct the final template using the form data
    let snippet = `
[date=${this.date} time=${shortcodeTime} timezone="${this.timezone}"]

**Event Details**
* **Date:** ${this.date}
* **Start time:** ${this.time}
* **Location name:** ${this.locationName}
* **Address:** ${this.address}
* **County:** ${this.county}
* **RSVP:** ${this.rsvpLink || 'None'}
`;
    
    if (this.isPublic) {
        snippet += '\n\n';
    } else {
        snippet += '\n\n';
    }

    // Insert the snippet into the composer's text area
    this.composer.model.addText(snippet);
    this.closeModal();
  }

  @action
  closeModal() {
    this.modal.close();
  }
}
