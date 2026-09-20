import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {createRequire} from 'node:module';
const [dependencies,sourcePath,output]=process.argv.slice(2);
if(!dependencies||!sourcePath||!output)throw new Error('Usage: node catalog-courses.mjs NODE_DEPENDENCY_DIRECTORY EXCEL_FILE OUTPUT.json');
const require=createRequire(path.resolve(dependencies,'package.json'));
const module=require('read-excel-file/node');const readExcelFile=module.default||module;
function text(row, key) {
  const value = row[key];
  if (value === undefined || value === null) {
    return "";
  }
  if (value instanceof Date) {
    return value.toISOString().slice(0, 10);
  }
  return String(value).trim();
}

function numberOrNull(row, key) {
  const textValue=text(row,key);if(!textValue)return null;
  const value = Number(textValue);
  return Number.isFinite(value) ? value : null;
}

function intOrNull(row, key) {
  const value = Number.parseInt(text(row, key), 10);
  return Number.isFinite(value) ? value : null;
}

function sheetRowsToObjects(data) {
  const headerRowIndex = data.findIndex((row) => row.some((cell) => text({ cell }, "cell")));
  if (headerRowIndex === -1) {
    return [];
  }

  const headers = data[headerRowIndex].map((cell) => text({ cell }, "cell"));
  return data.slice(headerRowIndex + 1)
    .filter((row) => row.some((cell) => text({ cell }, "cell")))
    .map((row) => {
      const object = {};
      headers.forEach((header, index) => {
        if (header) {
          object[header] = row[index] ?? "";
        }
      });
      return object;
    });
}

const sheets=await readExcelFile(sourcePath);
const courses=[];
for(const sheet of sheets){for(const row of sheetRowsToObjects(sheet.data)){
 const classNo=text(row,'课程序号'),courseCode=text(row,'课程代码'),title=text(row,'课程名称'),term=text(row,'学年度学期')||null;
 if(!classNo||!courseCode||!title)continue;
 courses.push({
          classNo,
          courseCode,
          title,
          category: text(row, "课程类别名称") || null,
          teachers: text(row, "授课教师"),
          teacherIds: text(row, "教师工号") || null,
          teacherDepartments: text(row, "教师院系") || null,
          teacherTitles: text(row, "职称") || null,
          credits: numberOrNull(row, "学分"),
          term,
          language: text(row, "授课语言") || null,
          openingDepartment: text(row, "开课院系") || null,
          className: text(row, "教学班名称") || null,
          grade: text(row, "年级") || null,
          educationLevel: text(row, "学历层次") || null,
          studentCategory: text(row, "学生类别") || null,
          major: text(row, "专业") || null,
          enrolled: intOrNull(row, "实际人数"),
          capacity: intOrNull(row, "容量"),
          scheduleInfo: text(row, "排课信息") || null,
          weeks: text(row, "周数") || null,
          period: text(row, "起止周") || null,
          weeklyHours: text(row, "周课时") || null,
          totalHours: text(row, "总课时") || null,
          classroomType: text(row, "教室类型") || null,
          classTime: text(row, "上课时间") || null,
          location: text(row, "上课地点") || null,
          campus: text(row, "校区") || null,
          assessment: text(row, "考核方式") || null,
          examTime: text(row, "考试时间") || null,
          rawJson: JSON.stringify(row), });
}}
const raw=JSON.stringify({format:'riverside-course-catalog-v1',courses,mentors:[]},null,2);
fs.writeFileSync(output,raw,{flag:'wx',mode:0o600});
console.log(JSON.stringify({courses:courses.length,sha256:crypto.createHash('sha256').update(raw).digest('hex')}));
