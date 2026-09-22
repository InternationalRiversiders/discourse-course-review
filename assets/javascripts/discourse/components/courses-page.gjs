import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { modifier } from "ember-modifier";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import AppForm from "./courses-form";
import AppCard from "./courses-card";
import AppIcon from "./courses-icon";

export default class extends Component {
  @service dialog;
  @tracked snapshot;
  mount = modifier(() => {
    const listener = () => this.navigate(Object.fromEntries(new URLSearchParams(window.location.search)), null, true);
    window.addEventListener("popstate", listener);
    return () => window.removeEventListener("popstate", listener);
  });
  @tracked busy = false;
  @tracked error = "";
  @tracked notice = "";
  get data() {
    return this.snapshot || this.args.model;
  }
  get query() {
    return new URLSearchParams(window.location.search);
  }
  @action async navigate(query, event, fromHistory = false) {
    if (
      event &&
      (event.metaKey ||
        event.ctrlKey ||
        event.shiftKey ||
        event.altKey ||
        event.button > 0)
    ) {
      return;
    }
    event?.preventDefault();
    this.busy = true;
    this.error = "";
    this.notice = "";
    try {
      const search = new URLSearchParams(query).toString();
      this.snapshot = await ajax("/courses/state.json?" + search);
      if (!fromHistory && window.location.search !== "?" + search) { window.history.pushState({}, "", "/courses?" + search); }
      window.scrollTo({ top: 0, behavior: "auto" });
    } catch (e) {
      this.error = extractError(e);
    } finally {
      this.busy = false;
    }
  }
  @action tab(id, e) {
    return this.navigate({ view: id }, e);
  }
  @action async search(e) {
    e.preventDefault();
    const query = Object.fromEntries(new FormData(e.target));
    query.view = this.data.view === "home" ? "courses" : this.data.view;
    return this.navigate(query);
  }
  @action async execute(op, data, requestId) {
    this.error = "";
    this.notice = "";
    const result = await ajax("/courses/action", {
      type: "POST",
      contentType: "application/json",
      data: JSON.stringify({ operation: op, data, request_id: requestId }),
    });
    if (result.query) {
      await this.navigate(result.query);
    } else {
      this.snapshot = await ajax("/courses/state.json?" + this.query.toString());
    }
    this.notice = result.message || "已保存";
    return result;
  }
  @action async button(item) {
    if (this.busy) {
      return;
    }
    if (item.confirm && !(await new Promise((resolve) => this.dialog.confirm({message:item.confirm,didConfirm:()=>resolve(true),didCancel:()=>resolve(false)})))) { return; }
    this.busy = true;
    try {
      await this.execute(item.operation, item.data, crypto.randomUUID());
    } catch (e) {
      this.error = extractError(e);
    } finally {
      this.busy = false;
    }
  }
  get isDetail() {
    return [
      "post",
      "review",
      "shop",
      "course",
      "mentor",
      "teacher",
      "about",
    ].includes(this.data.view);
  }
  get hasCards() {
    return Boolean(this.data.cards?.length);
  }
  get hasForms() {
    return Boolean(this.data.forms?.length);
  }
  get showEmpty() {
    return !this.hasCards && !this.hasForms && !this.data.sections?.some((section) => section.cards?.length);
  }
  get workspaceClass() {
    return `river-workspace ${this.isDetail ? "is-detail" : ""} ${this.hasForms ? "has-forms" : ""} ${!this.hasCards && this.hasForms ? "form-only" : ""}`;
  }
  get currentTitle() {
    return (
      this.data.tabs.find((tab) => tab.id === this.data.view)?.label ||
      {
        post: "树洞里的对话",
        review: "评价与讨论",
        shop: "店铺详情",
        course: "课程详情",
        mentor: "导师详情",
        teacher: "任课教师",
      }[this.data.view] ||
      "内容详情"
    );
  }
  get primaryFilter() {
    return this.data.filters[0];
  }
  get extraFilters() {
    return this.data.filters.slice(1);
  }
  get activeFilters() {
    return this.extraFilters.some((field) => Boolean(field.value));
  }
  <template>
    <main
      class="river-app river-courses"
      data-view={{this.data.view}}
      aria-busy={{this.busy}}
      {{this.mount}}
    >
      <h1 class="sr-only">{{this.data.title}}</h1>
      <nav class="river-tabs" aria-label="功能导航">{{#each
          this.data.tabs key="id"
          as |tab|
        }}<button
            type="button"
            class={{if (eq tab.id this.data.view) "is-active"}}
            aria-current={{if (eq tab.id this.data.view) "page"}}
            disabled={{this.busy}}
            {{on "click" (fn this.tab tab.id)}}
          >{{tab.label}}</button>{{/each}}</nav>
      {{#if this.data.readonly}}<p class="river-note" role="status">真实数据只读预览；发布、修改和互动请使用演示入口。</p>{{/if}}
      {{#if this.data.export_url}}<p><a href={{this.data.export_url}} download>下载我的评价与收藏数据</a></p>{{/if}}
      {{#if this.error}}<div
          class="river-error"
          role="alert"
        >{{this.error}}</div>{{/if}}
      {{#if this.notice}}<div class="river-notice" role="status"><AppIcon
            @kind="check"
          />{{this.notice}}</div>{{/if}}

      {{#if this.data.stats}}<div class="river-stats">{{#each
            this.data.stats
            as |stat|
          }}<div><span>{{stat.label}}</span><strong
              >{{stat.value}}</strong></div>{{/each}}</div>{{/if}}
      {{#if this.data.filters}}<form
          class="river-search"
          role="search"
          {{on "submit" this.search}}
        >
          <div class="river-search-main"><span
              class="river-search-mark"
            ><AppIcon @kind="search" /></span><label
            >{{this.primaryFilter.label}}<input
                type="search"
                disabled={{this.busy}}
                name={{this.primaryFilter.name}}
                value={{this.primaryFilter.value}}
                placeholder={{this.primaryFilter.placeholder}}
              /></label><button
              class="btn btn-primary"
              type="submit"
              disabled={{this.busy}}
            >筛选<AppIcon @kind="arrow" /></button></div>
          {{#if this.extraFilters.length}}<details
              class="river-filter-extra"
              open={{this.activeFilters}}
            ><summary>更多筛选</summary><div class="river-filter-fields">{{#each
                  this.extraFilters
                  as |field|
                }}<label>{{field.label}}{{#if field.options}}<select disabled={{this.busy}} name={{field.name}} aria-label={{field.label}}>{{#each field.options as |choice|}}<option value={{choice.value}} selected={{eq choice.value field.value}}>{{choice.label}}</option>{{/each}}</select>{{else}}<input type="text" name={{field.name}} value={{field.value}} placeholder={{field.placeholder}} />{{/if}}</label>{{/each}}</div></details>{{/if}}
        </form>{{/if}}

      {{#if this.data.note}}<p class="river-note"><AppIcon @kind="book" /><span
          >{{this.data.note}}</span></p>{{/if}}

      {{#each this.data.sections key="id" as |group|}}
        <section class="river-course-section" data-section={{group.id}} aria-label={{group.title}}>
          <div class="river-section-heading"><div><h2>{{group.title}}</h2>{{#if group.description}}<p>{{group.description}}</p>{{/if}}</div>
            {{#if group.more}}<button class="btn btn-flat" type="button" {{on "click" (fn this.navigate group.more.query)}}>{{group.more.label}}<AppIcon @kind="arrow" /></button>{{/if}}</div>
          <div class="river-grid">{{#each group.cards key="id" as |card|}}<AppCard @card={{card}} @busy={{this.busy}} @navigate={{this.navigate}} @button={{this.button}} @execute={{this.execute}} />{{else}}<p class="river-note">还没有相关内容，等第一条真实体验。</p>{{/each}}</div>
        </section>
      {{/each}}
      <div class={{this.workspaceClass}}>
        {{#if this.hasCards}}<section
            class="river-content"
            aria-label={{this.currentTitle}}
          ><div class="river-section-heading"><h2
              >{{this.currentTitle}}</h2><span
              >把真实经验，留给下一位同学</span></div>
            <div class="river-grid">{{#each
                this.data.cards key="id"
                as |card|
              }}<AppCard
                  @card={{card}}
                  @busy={{this.busy}}
                  @navigate={{this.navigate}}
                  @button={{this.button}}
                  @execute={{this.execute}}
                />{{/each}}</div>
          </section>{{/if}}
        {{#if this.hasForms}}<section
            class="river-forms"
            aria-label="填写与操作"
          >{{#each this.data.forms key="key" as |form|}}<AppForm
                @form={{form}}
                @execute={{this.execute}}
              />{{/each}}</section>{{/if}}
        {{#if this.showEmpty}}<div class="river-empty"><span
              class="river-empty-icon"
            ><AppIcon @kind="book" /></span><strong
            >{{this.data.empty_title}}</strong><p
            >{{this.data.empty_text}}</p></div>{{/if}}
      </div>
      {{#if this.data.pagination}}<nav class="river-pagination" aria-label="分页">
        {{#if this.data.previous}}<button class="btn" type="button" disabled={{this.busy}} {{on "click" (fn this.navigate this.data.previous)}}>上一页</button>{{/if}}
        <span>第 {{this.data.pagination.page}} / {{this.data.pagination.pages}} 页 · 共 {{this.data.pagination.total}} 条</span>
        {{#if this.data.next}}<button class="btn" type="button" disabled={{this.busy}} {{on "click" (fn this.navigate this.data.next)}}>下一页<AppIcon @kind="arrow" /></button>{{/if}}
      </nav>{{/if}}
    </main>
  </template>
}
