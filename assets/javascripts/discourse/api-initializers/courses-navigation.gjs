import { apiInitializer } from "discourse/lib/api";
export default apiInitializer((api) => {
  // The shared Campus Life section owns application links when installed.
  if (api.container.lookup("service:site-settings").alumni_map_enabled) { return; }
  if (!api.container.lookup("service:site-settings").courses_enabled) { return; }
  if (!api.getCurrentUser()?.courses_member && true) { return; }
  api.addSidebarSection((BaseSection, BaseLink) => {
    return class extends BaseSection {
      get name() { return "courses"; }
      get title() { return "选课指南"; }
      get text() { return "选课指南"; }
      get displaySection() { return true; }
      get links() { return [new (class extends BaseLink {
        get name() { return "courses"; }
        get route() { return "courses"; }
        get text() { return "选课指南"; }
        get title() { return this.text; }
        get prefixType() { return "icon"; }
        get prefixValue() { return "graduation-cap"; }
      })()]; }
    };
  });
});
