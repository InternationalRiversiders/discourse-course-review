import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
export default class extends Component {
  @tracked selected;
  get value() { return this.selected ?? (this.args.field.value || "0"); }
  get display() { return Number(this.value) > 0 ? Number(this.value).toFixed(1) : "请选择"; }
  @action change(event) { this.selected = event.target.value; }
  <template>
    <span class="river-rating-input"><input type="range" name={{@field.name}} aria-label={{@field.label}} min="0" max="5" step="0.5" value={{this.value}} {{on "input" this.change}} /><output>{{this.display}} <span aria-hidden="true">★</span></output></span>
  </template>
}
