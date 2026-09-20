import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import AppForm from "./courses-form";
import AppIcon from "./courses-icon";
const href = (query) => "/courses?" + new URLSearchParams(query).toString();
export default class extends Component {
  get date() {
    return this.args.card.created_at ? new Intl.DateTimeFormat("zh-CN", {dateStyle:"medium", timeStyle:"short"}).format(new Date(this.args.card.created_at)) : "";
  }
  get initial() {
    return Array.from(this.args.card.title || "")
      .slice(0, 1)
      .join("");
  }
  <template>
    <article class="river-card" data-card-id={{@card.id}} data-card-type={{@card.type}}>
      <div class="river-card-heading">
        <span class="river-card-symbol" aria-hidden="true"><AppIcon
            @kind="book"
          /></span>
        <div class="river-card-heading-text">{{#if @card.tag}}<span
              class="river-tag"
            >{{@card.tag}}</span>{{/if}}
          <h2>{{@card.title}}</h2>{{#if @card.subtitle}}<p
              class="river-meta"
            >{{@card.subtitle}}</p>{{/if}}
        </div>
      </div>
      {{#if @card.badge}}<span class="river-popularity">{{@card.badge}}</span>{{/if}}
      {{#if @card.status}}<p class="river-card-status">{{@card.status}}{{#if @card.hidden_reason}} · {{@card.hidden_reason}}{{/if}}</p>{{/if}}
      {{#if @card.created_at}}<time class="river-meta" datetime={{@card.created_at}}>{{this.date}}</time>{{/if}}
      {{#if @card.images}}<div class="river-images">{{#each
            @card.images
            as |url|
          }}<a href={{url}} target="_blank" rel="noopener"><img
                src={{url}}
                alt={{@card.title}}
                loading="lazy"
              /></a>{{/each}}</div>{{/if}}
      {{#if @card.body}}<p class="river-body">{{@card.body}}</p>{{/if}}
      {{#if @card.advice}}<blockquote class="river-advice">{{@card.advice}}</blockquote>{{/if}}
      {{#if @card.details.length}}<dl class="river-course-details">{{#each @card.details as |detail|}}<div><dt>{{detail.label}}</dt><dd>{{detail.value}}</dd></div>{{/each}}</dl>{{/if}}
      {{#each @card.external_links as |link|}}<a href={{link.url}} target="_blank" rel="noopener noreferrer">{{link.label}} ↗</a>{{/each}}
      {{#if @card.metrics}}<dl class="river-metrics">{{#each
            @card.metrics
            as |metric|
          }}<div><dt>{{metric.label}}</dt><dd
              >{{metric.value}}</dd></div>{{/each}}</dl>{{/if}}
      {{#if @card.links.length}}<div class="river-card-links">{{#each
            @card.links
            as |link|
          }}<a
              href={{href link.query}}
              {{on "click" (fn @navigate link.query)}}
            >{{link.label}}<AppIcon @kind="arrow" /></a>{{/each}}</div>{{/if}}
      {{#if @card.actions.length}}<div class="river-actions">{{#each
            @card.actions
            as |item|
          }}<button
              class="btn btn-default btn-small"
              type="button"
              disabled={{@busy}}
              {{on "click" (fn @button item)}}
            >{{item.label}}</button>{{/each}}</div>{{/if}}
      {{#each @card.forms key="key" as |form|}}<details
          class="river-discussion-form"
        ><summary>{{if form.title form.title "回复"}}</summary><AppForm
            @form={{form}}
            @execute={{@execute}}
          /></details>{{/each}}
    </article>
  </template>
}
