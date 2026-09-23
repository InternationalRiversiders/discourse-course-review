import { formatDateTime } from "../lib/campus-time";
import ForumUser from "./courses-user";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { not } from "discourse/truth-helpers";
import AppForm from "./courses-form";
import AppIcon from "./courses-icon";
const href = (query) => "/courses?" + new URLSearchParams(query).toString();
export default class extends Component {
  @tracked openForm;
  @tracked visitedForms = [];
  get date() { return formatDateTime(this.args.card.created_at); }
  get isCourse() { return this.args.card.type === "course"; }
  get isReview() { return this.args.card.type === "review"; }
  get hideSubject() { return this.isReview && ["course", "mentor"].includes(this.args.view); }
  get primaryLink() {
    if (this.isCourse) { return this.args.card.links?.find(link => link.query.view === "course"); }
    if (this.isReview && this.args.view !== "review") { return this.args.card.links?.find(link => link.query.view === "review"); }
  }
  get subjectLink() { return this.isReview && this.args.card.subject_query; }
  get links() {
    return (this.args.card.links || []).filter(link => {
      if (this.isCourse) { return link !== this.primaryLink; }
      if (this.isReview) { return !["查看详情", "课程详情"].includes(link.label) && link.query.view !== "review"; }
      return true;
    });
  }
  get again() {
    if (!this.isReview || this.args.card.take_again == null) { return null; }
    return this.args.card.take_again ? { label: "愿意再选", className: "is-positive" } : { label: "不愿再选", className: "is-negative" };
  }
  get forms() {
    return (this.args.card.forms || []).map(form => ({ ...form,
      expanded: this.openForm === form.key, mounted: this.visitedForms.includes(form.key),
      label: form.operation === "comment" ? `讨论${this.args.card.discussion_count == null ? "" : ` ${this.args.card.discussion_count}`}` : form.operation === "moderate" ? "管理" : form.title || "回复",
    }));
  }
  get discussionLink() { return this.isReview && !this.forms.some(form => form.operation === "comment") && this.primaryLink; }
  get hasFooter() { return Boolean(this.args.card.actions?.length || this.links.length || this.forms.length || this.discussionLink); }
  @action toggleForm(key) {
    if (!this.visitedForms.includes(key)) { this.visitedForms = [...this.visitedForms, key]; }
    this.openForm = this.openForm === key ? null : key;
  }
  <template>
    <article class="river-card {{if this.primaryLink 'is-clickable'}}" data-card-id={{@card.id}} data-card-type={{@card.type}}>
      {{#if this.isCourse}}
        <div class="river-course-heading">
          <div class="river-course-title"><span class="river-course-icon"><AppIcon @kind="book" /></span><h2><a class="river-card-target" href={{href this.primaryLink.query}} {{on "click" (fn @navigate this.primaryLink.query)}}>{{@card.title}}</a></h2></div>
          <dl class="river-course-score">{{#each @card.metrics as |metric|}}<div><dt>{{metric.label}}</dt><dd>{{metric.value}}</dd></div>{{/each}}</dl>
        </div>
        {{#if @card.body}}<p class="river-course-teachers">{{@card.body}}</p>{{/if}}
        <div class="river-course-meta">{{#if @card.tag}}<span>{{@card.tag}}</span>{{/if}}{{#if @card.subtitle}}<span>{{@card.subtitle}}</span>{{/if}}</div>
        {{#if @card.badge}}<span class="river-popularity">{{@card.badge}}</span>{{/if}}
      {{else if this.isReview}}
        {{#unless this.hideSubject}}<div class="river-review-subject"><h2>{{#if this.primaryLink}}<a class="river-card-target" href={{href this.primaryLink.query}} {{on "click" (fn @navigate this.primaryLink.query)}}>{{@card.title}}</a>{{else if this.subjectLink}}<a href={{href this.subjectLink}} {{on "click" (fn @navigate this.subjectLink)}}>{{@card.title}}</a>{{else}}{{@card.title}}{{/if}}</h2>{{#if @card.subject_meta}}<p class="river-meta">{{@card.subject_meta}}</p>{{/if}}</div>
        {{else}}{{#if this.primaryLink}}<a class="river-card-target river-review-open" href={{href this.primaryLink.query}} aria-label="打开评价与讨论" {{on "click" (fn @navigate this.primaryLink.query)}}><span class="sr-only">打开评价与讨论</span></a>{{/if}}{{/unless}}
        <div class="river-review-byline"><div class="river-review-author"><ForumUser @user={{@card.forum_user}} @name={{@card.author_name}} />{{#if this.again}}<span class="river-choice-tag {{this.again.className}}">{{this.again.label}}</span>{{/if}}</div><time datetime={{@card.created_at}}>{{this.date}}</time></div>
        {{#if @card.study_term}}<p class="river-review-term">{{@card.study_term}}</p>{{/if}}
      {{else}}
        <div class="river-card-heading"><div class="river-card-heading-text">{{#if @card.author_title}}<ForumUser @user={{@card.forum_user}} @name={{@card.title}} />{{else}}{{#if @card.tag}}<span class="river-tag">{{@card.tag}}</span>{{/if}}<h2>{{@card.title}}</h2>{{/if}}{{#if @card.subtitle}}<p class="river-meta">{{@card.subtitle}}</p>{{/if}}</div>{{#if @card.created_at}}<time class="river-meta" datetime={{@card.created_at}}>{{this.date}}</time>{{/if}}</div>
      {{/if}}
      {{#if @card.status}}<p class="river-card-status">{{@card.status}}{{#if @card.hidden_reason}} · {{@card.hidden_reason}}{{/if}}</p>{{/if}}
      {{#if @card.images}}<div class="river-images">{{#each @card.images as |url|}}<a href={{url}} target="_blank" rel="noopener"><img src={{url}} alt={{@card.title}} loading="lazy" /></a>{{/each}}</div>{{/if}}
      {{#unless this.isCourse}}
        {{#if @card.body}}<p class="river-body">{{@card.body}}</p>{{/if}}
        {{#if @card.advice}}<blockquote class="river-advice"><span>给后来者的建议</span>{{@card.advice}}</blockquote>{{/if}}
        {{#unless this.isReview}}{{#if @card.details.length}}<dl class="river-course-details">{{#each @card.details as |detail|}}<div><dt>{{detail.label}}</dt><dd>{{detail.value}}</dd></div>{{/each}}</dl>{{/if}}{{/unless}}
        {{#each @card.external_links as |link|}}<a class="river-external-link" href={{link.url}} target="_blank" rel="noopener noreferrer">{{link.label}} ↗</a>{{/each}}
        {{#if @card.metrics}}<dl class="river-metrics">{{#each @card.metrics as |metric|}}<div><dt>{{metric.label}}</dt><dd>{{metric.value}}</dd></div>{{/each}}</dl>{{/if}}
      {{/unless}}
      {{#if this.hasFooter}}<div class="river-card-footer">
        {{#each @card.actions as |item|}}<button class="btn btn-flat btn-small" type="button" disabled={{@busy}} {{on "click" (fn @button item)}}>{{item.label}}</button>{{/each}}
        {{#if this.discussionLink}}<a href={{href this.discussionLink.query}} {{on "click" (fn @navigate this.discussionLink.query)}}>讨论 {{@card.discussion_count}}</a>{{/if}}
        {{#each this.links as |link|}}<a href={{href link.query}} {{on "click" (fn @navigate link.query)}}>{{link.label}}</a>{{/each}}
        {{#each this.forms key="key" as |form|}}<button class="btn btn-flat btn-small" type="button" aria-expanded={{form.expanded}} {{on "click" (fn this.toggleForm form.key)}}>{{form.label}}</button>{{/each}}
      </div>{{/if}}
      {{#each this.forms key="key" as |form|}}{{#if form.mounted}}<div class="river-card-editor" hidden={{not form.expanded}}><AppForm @form={{form}} @execute={{@execute}} /></div>{{/if}}{{/each}}
    </article>
  </template>
}
