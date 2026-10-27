const API_URL = import.meta.env.VITE_API_URL || '';

function getToken() {
  return localStorage.getItem('token');
}

function setToken(token) {
  localStorage.setItem('token', token);
}

function removeToken() {
  localStorage.removeItem('token');
}

function buildHeaders(contentType = true) {
  const headers = {};
  if (contentType) {
    headers['Content-Type'] = 'application/json';
  }
  const token = getToken();
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  return headers;
}

async function handleResponse(response) {
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const errorMessage = data.error || `Request failed with status ${response.status}`;
    const error = new Error(errorMessage);
    error.status = response.status;
    error.data = data;
    throw error;
  }
  return data;
}

async function request(url, options) {
  try {
    const res = await fetch(url, options);
    return await handleResponse(res);
  } catch (err) {
    if (err instanceof TypeError) {
      const error = new Error('Unable to connect to the API server. Please check your network connection.');
      error.status = 0;
      throw error;
    }
    throw err;
  }
}

export const api = {
  // Auth
  async register({ email, password, role = 'user' }) {
    return request(`${API_URL}/api/auth/register`, {
      method: 'POST',
      headers: buildHeaders(),
      body: JSON.stringify({ email, password, role }),
    });
  },

  async login({ email, password }) {
    const data = await request(`${API_URL}/api/auth/login`, {
      method: 'POST',
      headers: buildHeaders(),
      body: JSON.stringify({ email, password }),
    });
    if (data.token) {
      setToken(data.token);
    }
    return data;
  },

  logout() {
    removeToken();
  },

  isAuthenticated() {
    return !!getToken();
  },

  getToken,

  // Tickets
  async getTickets(params = {}) {
    const query = new URLSearchParams(params).toString();
    const url = query ? `${API_URL}/api/tickets?${query}` : `${API_URL}/api/tickets`;
    return request(url, {
      headers: buildHeaders(false),
    });
  },

  async createTicket(ticket) {
    return request(`${API_URL}/api/tickets`, {
      method: 'POST',
      headers: buildHeaders(),
      body: JSON.stringify(ticket),
    });
  },

  async updateTicket(id, updates) {
    return request(`${API_URL}/api/tickets/${id}`, {
      method: 'PUT',
      headers: buildHeaders(),
      body: JSON.stringify(updates),
    });
  },

  async getStats() {
    return request(`${API_URL}/api/tickets/stats`, {
      headers: buildHeaders(false),
    });
  },
};
