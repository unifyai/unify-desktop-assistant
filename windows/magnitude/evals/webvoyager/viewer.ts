import { readdir, readFile } from "fs/promises";
import { join } from "path";
import * as readline from "readline";
import * as fs from "fs";

const port = 8000;
const resultsDir = "./results";
const TASKS_PATH = join(__dirname, "data", "patchedTasks.jsonl");

interface Task {
  web_name: string;
  id: string;
  ques: string;
  web: string;
}

interface EvalData {
  result: string;
  reasoning?: string;
}

async function findTaskById(taskId: string): Promise<Task | null> {
  const fileStream = fs.createReadStream(TASKS_PATH);
  const rl = readline.createInterface({
    input: fileStream,
    crlfDelay: Infinity,
  });

  for await (const line of rl) {
    try {
      const task: Task = JSON.parse(line);
      if (task.id === taskId) {
        return task;
      }
    } catch (error) {
      console.error("Error parsing JSON line:", error);
    }
  }
  return null;
}

const server = Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname;

    // API endpoints
    if (path === "/api/tasks") {
      return await getTasksList();
    } else if (path === "/api/tasks-summary") {
      return await getTasksSummary();
    } else if (path.startsWith("/api/task/")) {
      const taskName = decodeURIComponent(path.slice(10));
      return await getTaskData(taskName);
    } else if (path === "/" || path === "") {
      // Serve the HTML file
      try {
        const html = await Bun.file("./viewer.html").text();
        return new Response(html, {
          headers: { "content-type": "text/html" },
        });
      } catch {
        return new Response("visualizer.html not found", { status: 404 });
      }
    }

    return new Response("Not found", { status: 404 });
  },
});

async function getTasksList(): Promise<Response> {
  try {
    const files = await readdir(resultsDir);
    const tasks = files
      .filter(file => file.endsWith(".json") && !file.endsWith(".eval.json"))
      .map(file => file.slice(0, -5)) // Remove .json extension
      .sort();
    
    return new Response(JSON.stringify(tasks), {
      headers: { "content-type": "application/json" },
    });
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
}

async function getTasksSummary(): Promise<Response> {
  try {
    const files = await readdir(resultsDir);
    const taskFiles = files.filter(file => file.endsWith(".json") && !file.endsWith(".eval.json"));
    
    const categorizedTasks: Record<string, Array<{
      id: string;
      success?: boolean;
      time?: number;
      cost?: number;
      tokens?: number;
      actions?: number;
    }>> = {};
    
    for (const file of taskFiles) {
      const taskId = file.slice(0, -5);
      const [category] = taskId.split("--");
      
      if (!categorizedTasks[category]) {
        categorizedTasks[category] = [];
      }
      
      try {
        // Read task data
        const taskData = JSON.parse(await readFile(join(resultsDir, file), "utf-8"));
        
        // Try to read eval data
        let evalData: EvalData | null = null;
        try {
          const evalContent = await readFile(join(resultsDir, `${taskId}.eval.json`), "utf-8");
          evalData = JSON.parse(evalContent) as EvalData;
        } catch {
          // No eval data
        }
        
        categorizedTasks[category].push({
          id: taskId,
          success: evalData ? evalData.result === "SUCCESS" : undefined,
          time: taskData.time,
          cost: (taskData.totalInputCost || 0) + (taskData.totalOutputCost || 0),
          tokens: (taskData.totalInputTokens || 0) + (taskData.totalOutputTokens || 0),
          actions: taskData.actionCount
        });
      } catch (error) {
        console.error(`Error processing ${taskId}:`, error);
        categorizedTasks[category].push({
          id: taskId
        });
      }
    }
    
    // Sort tasks within each category by numeric suffix
    for (const category in categorizedTasks) {
      categorizedTasks[category].sort((a, b) => {
        const aNum = parseInt(a.id.split("--")[1] || "0");
        const bNum = parseInt(b.id.split("--")[1] || "0");
        return aNum - bNum;
      });
    }
    
    return new Response(JSON.stringify(categorizedTasks), {
      headers: { "content-type": "application/json" },
    });
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
}

async function getTaskData(taskName: string): Promise<Response> {
  try {
    const filePath = join(resultsDir, `${taskName}.json`);
    const evalFilePath = join(resultsDir, `${taskName}.eval.json`);
    
    const data = await readFile(filePath, "utf-8");
    const parsedData = JSON.parse(data);
    
    // Try to read evaluation data if it exists
    let evalData: EvalData | null = null;
    try {
      const evalContent = await readFile(evalFilePath, "utf-8");
      evalData = JSON.parse(evalContent) as EvalData;
    } catch {
      // Eval file doesn't exist, that's okay
    }
    
    // Get task information
    const task = await findTaskById(taskName);
    
    // Combine task data with eval data and task info
    const combinedData = {
      ...parsedData,
      evaluation: evalData,
      task: task
    };
    
    return new Response(JSON.stringify(combinedData), {
      headers: { "content-type": "application/json" },
    });
  } catch (error: any) {
    if (error.code === "ENOENT") {
      return new Response(JSON.stringify({ error: `Task not found: ${taskName}` }), {
        status: 404,
        headers: { "content-type": "application/json" },
      });
    }
    
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
}

console.log(`WebVoyager visualizer server running at http://localhost:${port}`);
console.log("Press Ctrl+C to stop the server");