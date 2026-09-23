import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
export default class extends Component {
  @tracked selected;
  get value() { return Number(this.selected ?? this.args.field.value ?? 0); }
  get display() { return this.value > 0 ? this.value.toFixed(1) : "请选择"; }
  get choices() {
    return Array.from({ length: 10 }, (_, index) => {
      const value = (index + 1) / 2;
      return { value, checked: value === this.value, className: `river-star-half ${index % 2 ? "is-right" : "is-left"} ${value <= this.value ? "is-filled" : ""}`, label: `${this.args.field.label} ${value} 分` };
    });
  }
  @action change(event) { this.selected = event.target.value; }
  <template>
    <div class="river-rating-input">
      <div class="river-stars" role="radiogroup" aria-label={{@field.label}}>
        {{#each this.choices key="value" as |choice|}}<label class={{choice.className}} title={{choice.label}}>
          <input class="sr-only" type="radio" name={{@field.name}} value={{choice.value}} checked={{choice.checked}} required={{@field.required}} aria-label={{choice.label}} {{on "change" this.change}} />
          <span aria-hidden="true">★</span>
        </label>{{/each}}
      </div>
      <output aria-live="polite">{{this.display}}</output>
    </div>
  </template>
}
