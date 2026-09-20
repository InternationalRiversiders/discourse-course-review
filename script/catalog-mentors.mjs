import path from 'node:path';
import crypto from 'node:crypto';
import {createRequire} from 'node:module';
const [dependencies,output,...args]=process.argv.slice(2);
if(!dependencies||!output)throw new Error('Usage: node catalog-mentors.mjs NODE_DEPENDENCY_DIRECTORY OUTPUT.json [--limit=N] [--only=CODE]');
const require=createRequire(path.resolve(dependencies,'package.json'));
const cheerio=require('cheerio');
const catalog=[];
import fs from "node:fs";




const BASE_URL = "https://yjsjy.uestc.edu.cn";
const LIST_URL = `${BASE_URL}/gmis/jcsjgl/dsfc/index/#01`;

const options = parseArgs(args);

function parseArgs(args) {
  const parsed = {
    concurrency: 3,
    delay: 500,
    dryRun: false,
    limit: null,
    only: null,
  };

  for (const arg of args) {
    if (arg === "--dry-run") {
      parsed.dryRun = true;
      continue;
    }

    const [key, rawValue] = arg.replace(/^--/, "").split("=");
    const value = rawValue ?? "";

    if (key === "fixtures") {
      parsed.fixtures = value;
    } else if (key === "limit") {
      parsed.limit = Number.parseInt(value, 10);
    } else if (key === "concurrency") {
      parsed.concurrency = Number.parseInt(value, 10);
    } else if (key === "delay") {
      parsed.delay = Number.parseInt(value, 10);
    } else if (key === "only") {
      parsed.only = value.trim();
    }
  }

  parsed.concurrency = clampNumber(parsed.concurrency, 1, 8, 3);
  parsed.delay = clampNumber(parsed.delay, 0, 5000, 500);
  parsed.limit = Number.isFinite(parsed.limit) && parsed.limit > 0 ? parsed.limit : null;

  return parsed;
}

function clampNumber(value, min, max, fallback) {
  if (!Number.isFinite(value)) {
    return fallback;
  }

  return Math.min(max, Math.max(min, value));
}

async function main() {
  const listHtml = await fetchText(LIST_URL);
  const mentors = parseMentorList(listHtml);
  const filteredMentors = options.only
    ? mentors.filter((mentor) =>
        [mentor.sourceKey, `${mentor.sourceKey}:${mentor.yxsh}`].includes(options.only),
      )
    : mentors;
  const targets = options.limit ? filteredMentors.slice(0, options.limit) : filteredMentors;

  console.log(
    `Found ${mentors.length} mentor links. Processing ${targets.length} with concurrency=${options.concurrency}, delay=${options.delay}ms, dryRun=${options.dryRun}.`,
  );

  let imported = 0;
  let failed = 0;
  const samples = [];

  await runPool(targets, options.concurrency, async (target, index) => {
    try {
      await sleep(options.delay * (index % options.concurrency));
      const html = await fetchText(target.profileUrl);
      const mentor = parseMentorDetail(html, target);

      if (samples.length < 5) {
        samples.push(mentor);
      }

      await upsertMentor(mentor);

      imported += 1;
    } catch (error) {
      failed += 1;
      console.error(`Failed ${target.sourceKey} ${target.name}:`, error.message);
    }
  });

  console.log(`Parsed ${imported} mentor profiles into a catalog file; failed ${failed}.`);

  if(failed)throw new Error('Incomplete scrape: refusing to write a partial catalog');
  const raw=JSON.stringify({format:'riverside-course-catalog-v1',courses:[],mentors:catalog},null,2);
  fs.writeFileSync(output,raw,{flag:'wx',mode:0o600});
  console.log(JSON.stringify({mentors:catalog.length,sha256:crypto.createHash('sha256').update(raw).digest('hex')}));
}

function toSampleSummary(mentor) {
  return {
    sourceKey: mentor.sourceKey,
    name: mentor.name,
    department: mentor.department,
    title: mentor.title,
    researchDirection: mentor.researchDirection,
    profileUrl: mentor.profileUrl,
    email: mentor.raw.email,
    photoUrl: mentor.raw.photoUrl,
    researchAreaCount: mentor.raw.researchAreas.length,
    biographyLength: mentor.raw.biography.length,
    projectsLength: mentor.raw.projects.length,
    achievementsLength: mentor.raw.achievements.length,
  };
}

function parseMentorList(html) {
  const $ = cheerio.load(html);
  const seen = new Set();
  const mentors = [];

  $('a[href^="/gmis/jcsjgl/dsfc/dsgrjj/"]').each((_, element) => {
    const href = $(element).attr("href");

    if (!href) {
      return;
    }

    const url = new URL(href, BASE_URL);
    const sourceKey = url.pathname.split("/").pop();
    const yxsh = url.searchParams.get("yxsh") ?? "";
    const name = cleanText($(element).find("div").first().text());
    const key = `${sourceKey}:${yxsh}`;

    if (!sourceKey || !name || seen.has(key)) {
      return;
    }

    seen.add(key);
    mentors.push({
      sourceKey,
      name,
      yxsh,
      profileUrl: url.toString(),
    });
  });

  return mentors;
}

function parseMentorDetail(html, listItem) {
  const $ = cheerio.load(html);
  const textById = (id) => cleanText($(`#${id}`).text());
  const code = textById("Labeldsdm") || listItem.sourceKey;
  const name = textById("Labeldsxm") || listItem.name;
  const department = textById("Labelxymc");
  const email = cleanText($("#Labelemail").parent().text());
  const researchAreas = parseResearchAreas($);
  const researchDirection = summarizeResearchDirections(researchAreas);
  const photoPath = $("#imgTutor").attr("src");
  const photoUrl = photoPath ? new URL(photoPath, BASE_URL).toString() : null;

  return {
    sourceKey: code,
    name,
    department: department || null,
    title: textById("Labelzc") || null,
    researchDirection: researchDirection || null,
    profileUrl: listItem.profileUrl,
    raw: {
      code,
      name,
      department,
      gender: textById("Labelxb"),
      specialTitle: textById("Labeltc"),
      title: textById("Labelzc"),
      degree: textById("Labelxw"),
      attribute: textById("Labelsx"),
      email,
      academicExperience: textById("Labelxsjl"),
      biography: textById("Labelgrjj"),
      projects: textById("lblKyxm"),
      achievements: textById("lblFbwz"),
      researchAreas,
      photoUrl,
      yxsh: listItem.yxsh,
      profileUrl: listItem.profileUrl,
      crawledAt: new Date().toISOString(),
    },
  };
}

function parseResearchAreas($) {
  const rows = [];

  $("table[border='1'] tr").each((index, element) => {
    if (index === 0) {
      return;
    }

    const cells = $(element)
      .find("td")
      .map((_, cell) => cleanText($(cell).text()))
      .get();

    if (cells.length >= 3 && cells.some(Boolean)) {
      rows.push({
        major: cells[0],
        direction: cells[1],
        admissionCategory: cells[2],
      });
    }
  });

  return rows;
}

function summarizeResearchDirections(rows) {
  return Array.from(
    new Set(rows.map((row) => row.direction).filter(Boolean)),
  ).join("；");
}

async function upsertMentor(mentor) {
 catalog.push({sourceKey:mentor.sourceKey,name:mentor.name,department:mentor.department,title:mentor.title,researchDirection:mentor.researchDirection,profileUrl:mentor.profileUrl,rawJson:JSON.stringify(mentor.raw)});
}

async function fetchText(url) {
  if (options.fixtures) {
    const key=new URL(url).pathname.split("/").filter(Boolean).pop();
    if(!/^[a-zA-Z0-9_-]+$/.test(key))throw new Error("Invalid fixture name");
    return fs.readFileSync(path.join(options.fixtures,key+".html"),"utf8");
  }
  const response = await fetch(url, {
    signal: AbortSignal.timeout(30000),
    headers: {
      "User-Agent":
        "Mozilla/5.0 (compatible; CourseReviewMentorImporter/1.0; +https://review.river-side.cc)",
    },
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status} for ${url}`);
  }

  return response.text();
}

async function runPool(items, concurrency, worker) {
  let cursor = 0;

  await Promise.all(
    Array.from({ length: concurrency }, async () => {
      while (cursor < items.length) {
        const index = cursor;
        cursor += 1;
        await worker(items[index], index);
      }
    }),
  );
}

function cleanText(value) {
  return value.replace(/\s+/g, " ").replace(/\u00a0/g, " ").trim();
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
