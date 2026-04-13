import axios from "axios";
export const getAdminUsers = () => axios.get("/admin/users");
export const getMetrics = () => fetch("/metrics/dashboard");
