// BAD: hardcoded API path literals
import axios from "axios";

export async function getUser(id: string) {
  return axios.get("/api/v1/users/" + id);
}

export async function createUser(data: any) {
  return fetch("/api/v1/users", {
    method: "POST",
    body: JSON.stringify(data),
  });
}
