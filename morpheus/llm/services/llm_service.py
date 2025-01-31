# Copyright (c) 2023-2024, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import logging
import typing
from abc import ABC
from abc import abstractmethod

logger = logging.getLogger(__name__)


class LLMClient(ABC):
    """
    Abstract interface for clients which are able to interact with LLM models. Concrete implementations of this class
    will have an associated implementation of `LLMService` which is able to construct instances of this class.
    """

    @abstractmethod
    def get_input_names(self) -> list[str]:
        """
        Returns the names of the inputs to the model.
        """
        pass

    @abstractmethod
    def generate(self, **input_dict) -> str:
        """
        Issue a request to generate a response based on a given prompt.

        Parameters
        ----------
        input_dict : dict
            Input containing prompt data.
        """
        pass

    @abstractmethod
    async def generate_async(self, **input_dict) -> str:
        """
        Issue an asynchronous request to generate a response based on a given prompt.

        Parameters
        ----------
        input_dict : dict
            Input containing prompt data.
        """
        pass

    @typing.overload
    @abstractmethod
    def generate_batch(self,
                       inputs: dict[str, list],
                       return_exceptions: typing.Literal[True] = True) -> list[str | BaseException]:
        ...

    @typing.overload
    @abstractmethod
    def generate_batch(self, inputs: dict[str, list], return_exceptions: typing.Literal[False] = False) -> list[str]:
        ...

    @abstractmethod
    def generate_batch(self, inputs: dict[str, list], return_exceptions=False) -> list[str] | list[str | BaseException]:
        """
        Issue a request to generate a list of responses based on a list of prompts.

        Parameters
        ----------
        inputs : dict
            Inputs containing prompt data.
        return_exceptions : bool
            Whether to return exceptions in the output list or raise them immediately.
        """
        pass

    @typing.overload
    @abstractmethod
    async def generate_batch_async(self,
                                   inputs: dict[str, list],
                                   return_exceptions: typing.Literal[True] = True) -> list[str | BaseException]:
        ...

    @typing.overload
    @abstractmethod
    async def generate_batch_async(self,
                                   inputs: dict[str, list],
                                   return_exceptions: typing.Literal[False] = False) -> list[str]:
        ...

    @abstractmethod
    async def generate_batch_async(self,
                                   inputs: dict[str, list],
                                   return_exceptions=False) -> list[str] | list[str | BaseException]:
        """
        Issue an asynchronous request to generate a list of responses based on a list of prompts.

        Parameters
        ----------
        inputs : dict
            Inputs containing prompt data.
        return_exceptions : bool
            Whether to return exceptions in the output list or raise them immediately.
        """
        pass


class LLMService(ABC):
    """
    Abstract interface for services which are able to construct clients for interacting with LLM models.
    """

    @abstractmethod
    def get_client(self, *, model_name: str, **model_kwargs) -> LLMClient:
        """
        Returns a client for interacting with a specific model.

        Parameters
        ----------
        model_name : str
            The name of the model to create a client for.

        model_kwargs : dict[str, typing.Any]
            Additional keyword arguments to pass to the model.
        """
        pass
