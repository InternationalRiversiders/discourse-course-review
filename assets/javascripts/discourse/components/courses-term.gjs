import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { eq } from "discourse/truth-helpers";
export default class extends Component {
  @tracked selectedYear;
  @tracked selectedSemester;
  get original() { return String(this.args.field.value || ""); }
  get parts() { return this.original.match(/^(\d{4}-\d{4})-([12])$/); }
  get year() { return this.selectedYear ?? (this.parts?.[1] || this.original); }
  get semester() { return this.selectedSemester ?? (this.parts?.[2] || ""); }
  get legacy() { return Boolean(this.year && !/^\d{4}-\d{4}$/.test(this.year)); }
  get yearRequired() { return Boolean(this.semester); }
  get semesterRequired() { return Boolean(this.year && !this.legacy); }
  get years() {
    const years = [...new Set((this.args.field.options || []).map(o => o.value.match(/^(\d{4}-\d{4})-[12]$/)?.[1]).filter(Boolean))];
    const options = years.map(value => ({ value, label: `${value} 学年` }));
    if (this.original && !this.parts) { options.unshift({ value: this.original, label: `原记录：${this.original}` }); }
    return options;
  }
  get value() { return this.legacy ? this.year : this.year && this.semester ? `${this.year}-${this.semester}` : ""; }
  @action changeYear(event) { this.selectedYear = event.target.value; if (this.legacy) { this.selectedSemester = ""; } }
  @action changeSemester(event) { this.selectedSemester = event.target.value; }
  <template>
    <div class="river-term-input">
      <input type="hidden" name={{@field.name}} value={{this.value}} />
      <label>修读学年<select aria-label="修读学年" required={{this.yearRequired}} {{on "change" this.changeYear}}>
        <option value="" selected={{eq this.year ""}}>未填写</option>
        {{#each this.years key="value" as |year|}}<option value={{year.value}} selected={{eq this.year year.value}}>{{year.label}}</option>{{/each}}
      </select></label>
      <label>学期<select aria-label="学期" disabled={{this.legacy}} required={{this.semesterRequired}} {{on "change" this.changeSemester}}>
        <option value="" selected={{eq this.semester ""}}>{{if this.legacy "沿用原记录" "未填写"}}</option>
        <option value="1" selected={{eq this.semester "1"}}>第一学期</option><option value="2" selected={{eq this.semester "2"}}>第二学期</option>
      </select></label>
    </div>
  </template>
}
