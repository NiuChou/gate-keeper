// GOOD: uses paths covered by rewrites
import axios from "axios";

export const getUsers = () => axios.get("/svc/users");
export const login = () => fetch("/api/auth/login");
